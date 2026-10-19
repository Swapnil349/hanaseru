import AVFoundation

enum VoiceEngineError: LocalizedError {
    case noMicrophone

    var errorDescription: String? {
        switch self {
        case .noMicrophone: "No microphone input is available."
        }
    }
}

/// One `AVAudioEngine` for the whole session: a microphone tap feeding the recogniser, plus a player
/// node for the "your turn" chime.
///
/// Keeping the engine running between turns keeps the audio session active, which is what lets a
/// session continue with the screen locked (spec §61, §62). Buffers only reach the recogniser while
/// it's the learner's turn; audio is never written to disk.
final class AudioEngineHost: @unchecked Sendable {
    enum Chime {
        case yourTurn
        case tick
        case nudge
        case reveal
        case complete
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// Plays the pre-recorded natural English voice.
    private let voicePlayer = AVAudioPlayerNode()
    private var voiceFormat: AVAudioFormat?
    private let chimeFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private let lock = NSLock()
    /// The recorded voice is scheduled and stopped here: AVAudioPlayerNode.stop() can block for a long time,
    /// and it must never block the screen.
    private let voiceQueue = DispatchQueue(label: "hanaseru.voice-player", qos: .userInitiated)
    // @Sendable: these run on the audio thread and must never be inferred as main-actor closures.
    private var consumer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var levelHandler: (@Sendable (Float) -> Void)?
    private var configurationObserver: NSObjectProtocol?

    var isRunning: Bool { engine.isRunning }

    /// Receives microphone buffers on the audio thread. Pass nil to stop feeding.
    func setConsumer(_ consumer: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        lock.withLock { self.consumer = consumer }
    }

    /// Receives a 0...1 input level on the audio thread (for the speaking indicator).
    func setLevelHandler(_ handler: (@Sendable (Float) -> Void)?) {
        lock.withLock { self.levelHandler = handler }
    }

    func start() throws {
        guard !engine.isRunning else { return }
        try installTap()
        if player.engine == nil {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: chimeFormat)
        }
        engine.prepare()
        try engine.start()
        observeConfigurationChanges()
    }

    func stop() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        setConsumer(nil)
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
    }

    /// Plays a recorded clip to the end, or until `stopClip()` or the calling task is cancelled (true). Returns
    /// false when it couldn't be heard — the engine isn't running, it stopped (a route change) or the clip ended
    /// far too soon — so the caller says the sentence with the iPhone voice instead of skipping it.
    func playClip(_ url: URL, volume: Float) async -> Bool {
        guard engine.isRunning, let file = try? AVAudioFile(forReading: url) else { return false }
        let format = file.processingFormat
        lock.withLock {
            if voicePlayer.engine == nil { engine.attach(voicePlayer) }
            if voiceFormat != format {
                engine.connect(voicePlayer, to: engine.mainMixerNode, format: format)
                voiceFormat = format
            }
        }
        voicePlayer.volume = volume
        let duration = Double(file.length) / max(format.sampleRate, 1)
        let once = ResumeOnce()
        let player = voicePlayer
        let audioEngine = engine
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                once.set(continuation)
                voiceQueue.async {
                    // The engine can stop between the check above and here (a route change), and playing a node of
                    // a stopped engine raises an exception.
                    guard audioEngine.isRunning else {
                        if once.resume(false) { VoiceLog.add("audio engine stopped before a recording could play") }
                        return
                    }
                    let startedAt = Date()
                    player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { _ in
                        // A clip "played back" in a fraction of its length was cut off (the engine stopped).
                        let played = duration < 0.5 || Date().timeIntervalSince(startedAt) >= duration * 0.5
                        if once.resume(played) && !played { VoiceLog.add("a recording was cut off") }
                    }
                    if !player.isPlaying { player.play() }
                }
                // If the engine stalls (route change) the clip never reports its end: don't wait in silence.
                DispatchQueue.global().asyncAfter(deadline: .now() + duration + 3) { [weak self] in
                    guard once.resume(false) else { return }
                    VoiceLog.add("a recording didn't finish playing")
                    self?.stopClip()
                }
            }
        } onCancel: {
            once.resume(true)
            self.stopClip()
        }
    }

    func stopClip() {
        let player = voicePlayer
        voiceQueue.async { player.stop() }
    }

    /// Starts the engine away from the main thread (starting audio hardware can take a moment).
    func startInBackground() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            voiceQueue.async {
                do {
                    try self.start()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Stops and starts the engine afresh, away from the main thread (after the media services were reset).
    /// The microphone consumer and level handler are kept.
    func restartInBackground() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            voiceQueue.async {
                do {
                    if let observer = self.configurationObserver { NotificationCenter.default.removeObserver(observer) }
                    self.configurationObserver = nil
                    self.voicePlayer.stop()
                    self.player.stop()
                    self.engine.inputNode.removeTap(onBus: 0)
                    self.engine.stop()
                    self.engine.reset()
                    try self.start()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func playChime(_ chime: Chime) {
        guard engine.isRunning, let buffer = makeChime(chime) else { return }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
    }

    // MARK: - Private

    private func installTap() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceEngineError.noMicrophone }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        let (consumer, levelHandler) = lock.withLock { (self.consumer, self.levelHandler) }
        consumer?(buffer)
        guard let levelHandler, let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        let decibels = 20 * log10(max(rms, 0.000_01))
        levelHandler(max(0, min(1, (decibels + 50) / 45)))
    }

    /// Route changes (e.g. AirPods connecting) change the input format and stop the engine; rebuild the tap and
    /// restart — on the voice queue, because starting audio hardware blocks and the screen must not.
    private func observeConfigurationChanges() {
        guard configurationObserver == nil else { return }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            VoiceLog.add("audio engine configuration changed; restarting the microphone")
            self.voiceQueue.async {
                do {
                    try self.installTap()
                    self.engine.prepare()
                    try self.engine.start()
                    VoiceLog.add("audio engine restarted after the configuration change")
                } catch {
                    VoiceLog.add("audio engine restart failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// A short two-note rising chime, in the spirit of a station departure melody's first notes.
    private func makeChime(_ chime: Chime) -> AVAudioPCMBuffer? {
        let notes: [(frequency: Double, duration: Double)] = switch chime {
        case .yourTurn: [(frequency: 880.0, duration: 0.09), (frequency: 1318.5, duration: 0.13)]
        case .tick: [(frequency: 1568.0, duration: 0.06)]
        case .nudge: [(frequency: 1046.5, duration: 0.08)]
        case .reveal: [(frequency: 659.3, duration: 0.12)]
        case .complete: [(frequency: 1318.5, duration: 0.1), (frequency: 1046.5, duration: 0.1), (frequency: 1568.0, duration: 0.18)]
        }
        let sampleRate = chimeFormat.sampleRate
        let totalFrames = AVAudioFrameCount(notes.map(\.duration).reduce(0, +) * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: chimeFormat, frameCapacity: totalFrames),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = totalFrames

        var frame = 0
        for note in notes {
            let frames = Int(note.duration * sampleRate)
            let fade = Int(0.012 * sampleRate)
            for i in 0..<frames where frame < Int(totalFrames) {
                let envelope = min(1, Double(i) / Double(fade), Double(frames - i) / Double(fade))
                channel[frame] = Float(sin(2 * .pi * note.frequency * Double(i) / sampleRate) * 0.22 * envelope)
                frame += 1
            }
        }
        return buffer
    }
}

/// Resumes a continuation exactly once, whichever thread gets there first. A value that arrives before the
/// continuation is set (a task cancelled at once) is kept and delivered when it is.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var early: Bool?
    private var done = false

    func set(_ continuation: CheckedContinuation<Bool, Never>) {
        let value = lock.withLock { () -> Bool? in
            if let early { return early }
            self.continuation = continuation
            return nil
        }
        if let value { continuation.resume(returning: value) }
    }

    /// True for the call that decided the result.
    @discardableResult
    func resume(_ value: Bool) -> Bool {
        let (decided, pending) = lock.withLock { () -> (Bool, CheckedContinuation<Bool, Never>?) in
            guard !done else { return (false, nil) }
            done = true
            let pending = continuation
            continuation = nil
            if pending == nil { early = value }
            return (true, pending)
        }
        pending?.resume(returning: value)
        return decided
    }
}
