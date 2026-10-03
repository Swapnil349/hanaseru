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
/// iOS only routes these to the app that is currently "Now Playing", so this is best-effort.
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

    func updateNowPlaying(title: String, detail: String, isPaused: Bool) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: detail,
            MPMediaItemPropertyAlbumTitle: "Hanaseru",
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

/// Layer 3 of the architecture (spec §55): everything iOS-specific about voice, behind one object.
@MainActor
final class VoiceEngine {
    let audioSession = AudioSessionController()
    let engineHost = AudioEngineHost()
    let synthesizer: AppleSpeechSynthesisProvider
    let recognizer: AppleSpeechRecognitionProvider
    let cues: CueFeedbackController
    let remote = RemoteCommandBridge()

    /// Microphone level 0...1, delivered on the main actor while a session is running.
    var onMicLevel: ((Float) -> Void)?

    init() {
        synthesizer = AppleSpeechSynthesisProvider()
        recognizer = AppleSpeechRecognitionProvider(engine: engineHost)
        cues = CueFeedbackController(engine: engineHost)
    }

    var runnerVoice: SessionRunner.Voice {
        SessionRunner.Voice(synthesizer: synthesizer, recognizer: recognizer, feedback: cues)
    }

    func beginSession() throws {
        try audioSession.activate()
        engineHost.setLevelHandler { [weak self] level in
            Task { @MainActor in self?.onMicLevel?(level) }
        }
        try engineHost.start()
        remote.activate()
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
