import Foundation
import LearningCore
import SessionCore

/// Plays a Listen playlist (docs/LISTEN.md): short scenes back to back, hands-free, with the screen locked too.
///
/// It has its own audio session controller, voice and lock-screen controls, so nothing a practice session set up is
/// touched; the two never play at once (`AppEnvironment.startListening` ends a session, and a session stops Listen
/// as it starts). The voice is the app's guarded speech provider without the audio engine: no microphone is needed,
/// and the English is always the iPhone's English voice (the recordings only cover the coach's cues).
@Observable
@MainActor
final class ListenPlayer {
    enum State: Equatable {
        /// Nothing playing: not started yet, or stopped.
        case idle
        /// The audio is being started (or brought back after a pause).
        case starting
        case playing
        case paused
        /// Played to the end; the playlist stays on screen.
        case finished
    }

    /// "Previous" restarts the scene once it has played this long; before that it goes back a scene.
    static let restartAfter: TimeInterval = 3

    private(set) var state: State = .idle
    private(set) var playlist: ListenPlaylist?
    /// The scene playing; `playlist.scenes.count` while the closing words are said.
    private(set) var sceneIndex = 0
    /// The utterance in that scene. After a pause it is said again from its start.
    private(set) var utteranceIndex = 0
    /// What is being said, for the screen.
    private(set) var current: ListenUtterance?

    private let audioSession = AudioSessionController()
    private let remote = RemoteCommandBridge()
    private let voice = AppleSpeechSynthesisProvider()
    private var playTask: Task<Void, Never>?
    /// Bumped whenever playback stops or jumps, so whatever was under way before doesn't carry on.
    private var generation = 0
    /// When the current scene started, moved on by any time spent paused (for "previous").
    private var sceneStartedAt = Date()
    private var pausedAt: Date?
    private var pausedByInterruption = false

    init() {
        // A line that made no sound is said again once the audio is back (see `SpeechGuard`).
        voice.onRecoverAudio = { [weak self] in await self?.activateAudio() }
        // Several lines in a row made no sound even after recovering: pause rather than go on in silence.
        voice.onSpeechLost = { [weak self] in self?.pause(reason: "no sound from the voice") }
    }

    /// Playing, paused or starting: something is on the lock screen.
    var isActive: Bool { state == .starting || state == .playing || state == .paused }
    var isPlaying: Bool { state == .starting || state == .playing }

    /// The scene playing (nil during the closing words).
    var scene: ListenScene? {
        guard let playlist, playlist.scenes.indices.contains(sceneIndex) else { return nil }
        return playlist.scenes[sceneIndex]
    }

    // MARK: - Controls

    /// Plays a playlist from its first scene. Use `AppEnvironment.startListening`, which ends a practice session first.
    func play(_ playlist: ListenPlaylist) {
        guard !playlist.isEmpty else { return }
        halt()
        self.playlist = playlist
        sceneIndex = 0
        utteranceIndex = 0
        current = nil
        pausedAt = nil
        pausedByInterruption = false
        wireControls()
        remote.activate()
        let minutes = Int((playlist.estimatedDuration / 60).rounded())
        VoiceLog.add("listen started: \(playlist.scenes.count) scenes, about \(minutes) min, "
                     + "\(playlist.choices.language.title), \(playlist.choices.speed.title), from \(playlist.source.title)")
        startPlaying()
    }

    func togglePlayPause(reason: String = "play button") {
        switch state {
        case .starting, .playing:
            pause(reason: reason)
        case .paused:
            resume(reason: reason)
        case .finished:
            if let playlist { play(playlist) }
        case .idle:
            break
        }
    }

    /// Stops at once, keeping the place: playing again says the current line again from its start.
    func pause(reason: String = "pause button") {
        guard isPlaying else { return }
        VoiceLog.add("listen paused (\(reason))")
        halt()
        state = .paused
        pausedAt = Date()
        updateNowPlaying()
    }

    func resume(reason: String = "play button") {
        guard state == .paused, playlist != nil else { return }
        VoiceLog.add("listen resumed (\(reason))")
        pausedByInterruption = false
        startPlaying()
    }

    func nextScene() {
        guard let playlist, isActive, sceneIndex < playlist.scenes.count else { return }
        move(to: sceneIndex + 1, reason: "next scene")
    }

    /// Back to the start of this scene, or to the previous scene in its first few seconds.
    func previousScene() {
        guard let playlist, isActive else { return }
        let played = (pausedAt ?? Date()).timeIntervalSince(sceneStartedAt)
        let target: Int
        if sceneIndex >= playlist.scenes.count {
            target = playlist.scenes.count - 1
        } else if sceneIndex == 0 || played > Self.restartAfter {
            target = sceneIndex
        } else {
            target = sceneIndex - 1
        }
        move(to: target, reason: target == sceneIndex ? "restart scene" : "previous scene")
    }

    /// Ends Listen: the lock screen and the audio are let go.
    func stop(reason: String = "stop button") {
        guard state != .idle else { return }
        VoiceLog.add("listen stopped (\(reason))")
        halt()
        if state != .finished { releaseAudio() }
        state = .idle
        playlist = nil
        current = nil
        pausedAt = nil
        pausedByInterruption = false
    }

    // MARK: - Playing

    /// Brings the audio up away from the main thread, then says the current utterance from its start and goes on.
    private func startPlaying() {
        generation += 1
        let token = generation
        state = .starting
        updateNowPlaying()
        Task { @MainActor in
            await activateAudio()
            guard generation == token else { return }
            if let since = pausedAt {
                sceneStartedAt = sceneStartedAt.addingTimeInterval(Date().timeIntervalSince(since))
                pausedAt = nil
            }
            state = .playing
            updateNowPlaying()
            playTask = Task { @MainActor [weak self] in await self?.run(token) }
        }
    }

    private func run(_ token: Int) async {
        while generation == token, !Task.isCancelled, let playlist = self.playlist {
            let part = utterances(of: sceneIndex, in: playlist)
            guard part.indices.contains(utteranceIndex) else {
                finish()
                return
            }
            if utteranceIndex == 0 { partStarted(playlist) }
            current = part[utteranceIndex]
            await voice.speak(part[utteranceIndex].request)
            guard generation == token, !Task.isCancelled else { return }
            utteranceIndex += 1
            if utteranceIndex >= part.count && sceneIndex < playlist.scenes.count {
                sceneIndex += 1
                utteranceIndex = 0
            }
        }
    }

    /// A scene's utterances, or the closing words after the last scene.
    private func utterances(of index: Int, in playlist: ListenPlaylist) -> [ListenUtterance] {
        if playlist.scenes.indices.contains(index) { return playlist.scenes[index].utterances }
        return index == playlist.scenes.count ? playlist.ending : []
    }

    private func partStarted(_ playlist: ListenPlaylist) {
        sceneStartedAt = Date()
        if let scene {
            // Heard: the next playlists start with other scenes. (Not marked as practised: nothing was said.)
            ListenHistory.remember(scene.id)
            VoiceLog.add("listen scene \(sceneIndex + 1) of \(playlist.scenes.count): \(scene.title)")
        } else {
            VoiceLog.add("listen: closing words")
        }
        updateNowPlaying()
    }

    private func move(to index: Int, reason: String) {
        guard let playlist else { return }
        let wasPaused = state == .paused
        halt()
        sceneIndex = min(max(index, 0), playlist.scenes.count)
        utteranceIndex = 0
        current = nil
        VoiceLog.add("listen \(reason): " + (scene.map { "scene \(sceneIndex + 1), \($0.title)" } ?? "closing words"))
        if wasPaused {
            // Stays paused at the start of that scene.
            sceneStartedAt = Date()
            pausedAt = sceneStartedAt
            updateNowPlaying()
        } else {
            startPlaying()
        }
    }

    private func finish() {
        VoiceLog.add("listen finished")
        generation += 1
        playTask = nil
        current = nil
        state = .finished
        releaseAudio()
    }

    /// Stops what is being said (never blocking: the voice hands over to a fresh synthesizer).
    private func halt() {
        generation += 1
        playTask?.cancel()
        playTask = nil
        voice.stopSpeaking()
    }

    // MARK: - Audio and the lock screen

    /// Spoken audio, away from the main thread.
    private func activateAudio() async {
        do {
            try await audioSession.activateForListeningInBackground()
        } catch {
            VoiceLog.add("listen: couldn't start the audio: \(error.localizedDescription)")
        }
    }

    /// The lock screen, AirPods and the car stop showing Listen; music that was playing may carry on.
    private func releaseAudio() {
        remote.deactivate()
        audioSession.deactivate()
    }

    private func wireControls() {
        remote.onToggle = { [weak self] in self?.togglePlayPause(reason: "headphone play/pause") }
        remote.onPause = { [weak self] in self?.pause(reason: "headphone pause") }
        remote.onResume = { [weak self] in self?.resume(reason: "headphone play") }
        remote.onSkip = { [weak self] in self?.nextScene() }
        remote.onPrevious = { [weak self] in self?.previousScene() }
        // A call or Siri pauses; playback carries on by itself afterwards when iOS says so.
        audioSession.onInterruption = { [weak self] event in
            guard let self else { return }
            switch event {
            case .began:
                guard self.isPlaying else { return }
                self.pause(reason: "audio interruption")
                self.pausedByInterruption = true
            case .ended(let shouldResume):
                guard self.state == .paused, self.pausedByInterruption else { return }
                self.pausedByInterruption = false
                if shouldResume { self.resume(reason: "end of interruption") }
            }
        }
        // Headphones out or the car disconnected: pause, as music does.
        audioSession.onRouteLost = { [weak self] in self?.pause(reason: "headphones disconnected") }
        // After a media services reset every audio object is dead: a new synthesizer, the audio again, the line again.
        audioSession.onMediaReset = { [weak self] in
            guard let self else { return }
            self.voice.replaceSynthesizer()
            guard self.isPlaying else { return }
            self.pause(reason: "media services reset")
            self.resume(reason: "media services reset")
        }
    }

    /// Title: the scene; artist: "Hanaseru · Listen"; album: Japanese only or Japanese + English (and the speed).
    private func updateNowPlaying() {
        guard let playlist, isActive else { return }
        let choices = playlist.choices
        let mode = choices.speed == .slower ? "\(choices.language.title) · \(choices.speed.title)" : choices.language.title
        remote.updateNowPlaying(title: scene?.title ?? "The end", detail: "Hanaseru · Listen", isPaused: state == .paused,
                                album: mode)
    }
}

/// The scenes played in Listen lately (the latest last), so the next playlists start with others.
enum ListenHistory {
    static var recent: [String] {
        UserDefaults.standard.stringArray(forKey: SettingsKey.listenRecent) ?? []
    }

    static func remember(_ id: String) {
        UserDefaults.standard.set(ListenPlaylist.remembering(id, in: recent), forKey: SettingsKey.listenRecent)
    }
}
