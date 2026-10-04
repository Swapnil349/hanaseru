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
    private let chimeFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private let lock = NSLock()
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

    /// Route changes (e.g. AirPods connecting) change the input format and stop the engine; rebuild the tap and restart.
    private func observeConfigurationChanges() {
        guard configurationObserver == nil else { return }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            VoiceLog.add("audio engine configuration changed; restarting the microphone")
            try? self.installTap()
            self.engine.prepare()
            do {
                try self.engine.start()
            } catch {
                VoiceLog.add("microphone restart failed: \(error.localizedDescription)")
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
