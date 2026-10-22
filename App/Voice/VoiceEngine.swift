import MediaPlayer
import SessionCore
import UIKit

/// Haptics + chime for turn-taking (spec §51). The chime matters most: with the phone in a pocket,
/// sound is the only cue you'll reliably notice.
@MainActor
final class CueFeedbackController: CueFeedbackProvider {
    private let engine: AudioEngineHost
    private let impact = UIImpactFeedbackGenerator(style: .medium)
    private let notification = UINotificationFeedbackGenerator()

    init(engine: AudioEngineHost) {
        self.engine = engine
    }

    func play(_ cue: HapticCue) {
        switch cue {
        case .yourTurn:
            engine.playChime(.yourTurn)
            impact.impactOccurred(intensity: 0.8)
        case .correct:
            engine.playChime(.tick)
            impact.impactOccurred(intensity: 0.3)
        case .nudge:
            engine.playChime(.nudge)
        case .reveal:
            // Neutral, never a failure sound.
            engine.playChime(.reveal)
            impact.impactOccurred(intensity: 0.3)
        case .sessionComplete:
            engine.playChime(.complete)
            notification.notificationOccurred(.success)
        }
    }
}

/// AirPods / lock-screen controls (spec §61): play-pause toggles the session, "next" skips an exercise.
/// iOS only routes these to the app that is currently "Now Playing", so this is best-effort. Listen has its own
/// bridge; only one of the two is active at a time (starting one stops the other).
@MainActor
final class RemoteCommandBridge {
    var onPause: (() -> Void)?
    var onResume: (() -> Void)?
    var onToggle: (() -> Void)?
    /// "Next track": during the learner's turn, give the answer and move on; otherwise skip.
    var onSkip: (() -> Void)?
    /// "Previous track": hear it again (もう一度).
    var onPrevious: (() -> Void)?

    private var registrations: [(MPRemoteCommand, Any)] = []

    func activate() {
        guard registrations.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        register(center.togglePlayPauseCommand) { [weak self] in self?.onToggle?() }
        register(center.pauseCommand) { [weak self] in self?.onPause?() }
        register(center.playCommand) { [weak self] in self?.onResume?() }
        register(center.nextTrackCommand) { [weak self] in self?.onSkip?() }
        register(center.previousTrackCommand) { [weak self] in self?.onPrevious?() }
        UIApplication.shared.beginReceivingRemoteControlEvents()
    }

    func deactivate() {
        for (command, token) in registrations { command.removeTarget(token) }
        registrations.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        UIApplication.shared.endReceivingRemoteControlEvents()
    }

    func updateNowPlaying(title: String, detail: String, isPaused: Bool, album: String = "Hanaseru") {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: detail,
            MPMediaItemPropertyAlbumTitle: album,
            MPNowPlayingInfoPropertyPlaybackRate: isPaused ? 0.0 : 1.0,
        ]
    }

    private func register(_ command: MPRemoteCommand, action: @escaping @MainActor () -> Void) {
        command.isEnabled = true
        let token = command.addTarget { _ in
            Task { @MainActor in action() }
            return .success
        }
        registrations.append((command, token))
    }
}

/// Lets a microphone level through at most every 80 ms, and only when it has changed noticeably.
final class LevelThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Float = -1
    private var sentAt = Date.distantPast

    func shouldSend(_ level: Float) -> Bool {
        lock.withLock {
            let now = Date()
            guard now.timeIntervalSince(sentAt) >= 0.08, abs(level - last) >= 0.04 else { return false }
            last = level
            sentAt = now
            return true
        }
    }
}

/// Layer 3 of the architecture (spec §55): everything iOS-specific about voice, behind one object.
@MainActor
final class VoiceEngine {
    let audioSession = AudioSessionController()
    let engineHost = AudioEngineHost()
    let synthesizer: AppleSpeechSynthesisProvider
    let recognizer: AppleSpeechRecognitionProvider
    let cues: CueFeedbackController
    let remote = RemoteCommandBridge()
    /// Writing instead of speaking (Apple Pencil on iPad, or a finger).
    let writing = WritingInput()

    /// Microphone level 0...1, delivered on the main actor while a session is running.
    var onMicLevel: ((Float) -> Void)?
    /// Several lines in a row made no sound, even after the audio was recovered.
    var onSpeechLost: (() -> Void)?

    init() {
        synthesizer = AppleSpeechSynthesisProvider(engine: engineHost)
        recognizer = AppleSpeechRecognitionProvider(engine: engineHost, writing: writing)
        cues = CueFeedbackController(engine: engineHost)
        // A line that made no sound is said again once the audio is back (see `SpeechGuard`).
        synthesizer.onRecoverAudio = { [weak self] in await self?.recover() }
        synthesizer.onSpeechLost = { [weak self] in self?.onSpeechLost?() }
    }

    var runnerVoice: SessionRunner.Voice {
        SessionRunner.Voice(synthesizer: synthesizer, recognizer: recognizer, feedback: cues)
    }

    /// Audio for a session. The slow parts (the audio session, the engine) run away from the main thread.
    func beginSession() async throws {
        try await audioSession.activateInBackground()
        // The microphone level reaches the screen a dozen times a second at most, and only when it changes.
        let throttle = LevelThrottle()
        engineHost.setLevelHandler { [weak self] level in
            guard throttle.shouldSend(level) else { return }
            Task { @MainActor in self?.onMicLevel?(level) }
        }
        try await engineHost.startInBackground()
        remote.activate()
    }

    /// Brings audio back after a pause, an interruption or a route change, without blocking the screen.
    /// `restartEngine`: stop and start the engine afresh (after the media services were reset). Never waits
    /// more than a few seconds: a busy audio thread mustn't leave the session stuck on "resuming".
    func recover(restartEngine: Bool = false) async {
        let finished = await Self.waitAtMost(6) { [weak self] in
            guard let self else { return }
            do {
                try await self.audioSession.activateInBackground()
                if restartEngine {
                    try await self.engineHost.restartInBackground()
                } else {
                    try await self.engineHost.startInBackground()
                }
                VoiceLog.add("audio recovered")
            } catch {
                VoiceLog.add("audio recovery failed: \(error.localizedDescription)")
            }
        }
        if !finished { VoiceLog.add("audio recovery still busy after 6 s; carrying on") }
    }

    /// Runs `work`, but returns after `seconds` even if it hasn't finished (false then).
    private static func waitAtMost(_ seconds: Double, _ work: @escaping @MainActor () async -> Void) async -> Bool {
        let gate = RecoveryGate()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            gate.continuation = continuation
            Task { @MainActor in
                await work()
                gate.open(true)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                gate.open(false)
            }
        }
    }

    func endSession() {
        synthesizer.stopSpeaking()
        recognizer.cancelListening()
        engineHost.setLevelHandler(nil)
        engineHost.stop()
        remote.deactivate()
        audioSession.deactivate()
    }
}

/// Resumes a waiting task once, with whichever result comes first (used on the main actor only).
private final class RecoveryGate {
    var continuation: CheckedContinuation<Bool, Never>?

    func open(_ finished: Bool) {
        continuation?.resume(returning: finished)
        continuation = nil
    }
}
