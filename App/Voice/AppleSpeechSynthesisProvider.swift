import AVFoundation
import LearningCore
import SessionCore

/// Japanese and English speech via `AVSpeechSynthesizer` (spec §61).
///
/// Picks the most natural installed voice (Premium, then Enhanced) unless the learner chose one in Settings.
/// Download "Premium" or "Enhanced" voices in iOS Settings › Accessibility › Spoken Content › Voices.
///
/// A guard watches every utterance (see `SpeechGuard`): iOS occasionally drops one without a sound — it never
/// starts (right after a stop, while the audio route changes), or it "finishes" at once because the audio session
/// was inactive or interrupted. Without the guard the session would wait in silence, or skip lines unheard; with
/// it, the audio is brought back and the utterance is said once more on a fresh synthesizer, then the session
/// goes on. Every such event is written to the voice log.
@MainActor
final class AppleSpeechSynthesisProvider: NSObject, SpeechSynthesisProvider {
    private enum Outcome {
        case finished, cancelled, neverStarted, stalled
    }

    private var synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var currentUtterance: ObjectIdentifier?
    private var started = false
    /// The last few utterances, kept alive: an identifier is only unique while its object lives, so a late
    /// callback for a finished utterance could otherwise be taken for the current one and end it unheard.
    private var recentUtterances: [AVSpeechUtterance] = []
    /// Lines in a row that made no sound even after the audio was recovered.
    private var silentLines = 0
    /// Plays the pre-recorded natural English (nil: always the iOS voice).
    private let engine: AudioEngineHost?

    /// Brings the audio session and engine back before a silent utterance is said again (set by `VoiceEngine`).
    var onRecoverAudio: (@MainActor () async -> Void)?
    /// Several lines in a row made no sound: the session should pause rather than go on in silence.
    var onSpeechLost: (@MainActor () -> Void)?

    init(engine: AudioEngineHost? = nil) {
        self.engine = engine
        super.init()
        configure(synthesizer)
    }

    private func configure(_ synthesizer: AVSpeechSynthesizer) {
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = true
    }

    func speak(_ request: SpeechRequest) async {
        guard !request.text.isEmpty else { return }
        if request.language == .english, request.voice == .coachEnglish, await speakRecorded(request) { return }
        for attempt in 1...2 {
            guard !Task.isCancelled else { return }
            let began = Date()
            let outcome = await speakOnce(request)
            let elapsed = Date().timeIntervalSince(began)
            guard !Task.isCancelled else { return }
            let verdict: SpeechGuard.Verdict
            switch outcome {
            case .cancelled:
                return
            case .stalled:
                // It was heard starting and its end was lost: going on beats saying it twice.
                VoiceLog.add("speech stalled, skipped: \(request.text.prefix(40))")
                resetSynthesizer()
                return
            case .neverStarted:
                verdict = .neverStarted
            case .finished:
                verdict = SpeechGuard.verdict(for: request, elapsed: elapsed)
            }
            switch SpeechGuard.nextStep(after: verdict, attempt: attempt) {
            case .done:
                silentLines = 0
                return
            case .recoverAndRetry:
                VoiceLog.add("speech \(Self.describe(verdict, elapsed: elapsed, request: request)) [\(Self.routeDescription)]; "
                             + "recovering the audio and saying it again: \(request.text.prefix(40))")
                resetSynthesizer()
                if let onRecoverAudio { await onRecoverAudio() }
            case .giveUp:
                silentLines += 1
                VoiceLog.add("speech \(Self.describe(verdict, elapsed: elapsed, request: request)) again; skipped after "
                             + "\(attempt) tries (\(silentLines) silent in a row): \(request.text.prefix(40))")
                resetSynthesizer()
                if silentLines >= SpeechGuard.silentLinesBeforePause {
                    silentLines = 0
                    VoiceLog.add("no sound for \(SpeechGuard.silentLinesBeforePause) lines in a row; pausing the session")
                    onSpeechLost?()
                }
                return
            }
        }
    }

    func stopSpeaking() {
        engine?.stopClip()
        finishCurrent(stop: true, outcome: .cancelled)
    }

    /// After the media services were reset every audio object is dead: speech goes on with a new synthesizer. An
    /// utterance in progress is caught by the guard and said again on the new one.
    func replaceSynthesizer() {
        VoiceLog.add("speech synthesizer replaced")
        resetSynthesizer()
        Self.resetVoiceCache()
    }

    /// The natural pre-recorded English, when every part of the sentence was recorded. False: use iOS speech.
    private func speakRecorded(_ request: SpeechRequest) async -> Bool {
        guard NaturalEnglishVoice.isEnabled, let engine,
              let clips = NaturalEnglishVoice.shared.recordings(for: request.text), !clips.isEmpty else {
            if NaturalEnglishVoice.shared.isAvailable { VoiceLog.add("not recorded, iPhone voice: \(request.text.prefix(50))") }
            return false
        }
        guard engine.isRunning else {
            VoiceLog.add("audio engine not running, iPhone voice instead of the recording: \(request.text.prefix(50))")
            return false
        }
        finishCurrent(stop: true, outcome: .cancelled)
        VoiceLog.add("say en (natural): \(request.text.prefix(50))")
        let volume = Float(request.volume < 1 && !Self.isUsingHeadphones ? 1 : request.volume)
        for clip in clips {
            guard !Task.isCancelled else { return true }
            let played = await engine.playClip(clip, volume: volume)
            guard !Task.isCancelled else { return true }
            if !played {
                // Never skip a sentence unheard: the iPhone voice says it instead.
                VoiceLog.add("recording didn't play, iPhone voice instead: \(request.text.prefix(50))")
                return false
            }
        }
        silentLines = 0
        if request.pauseAfter > 0 && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(request.pauseAfter * 1_000_000_000))
        }
        return true
    }

    private func speakOnce(_ request: SpeechRequest) async -> Outcome {
        finishCurrent(stop: true, outcome: .cancelled)

        let utterance = AVSpeechUtterance(string: request.text)
        let choice = Self.voice(for: request.voice, language: request.language)
        utterance.voice = choice.voice
        utterance.pitchMultiplier = choice.pitch
        utterance.rate = Self.rate(for: request.rate)
        utterance.postUtteranceDelay = request.pauseAfter
        // Whispered cues are quieter on headphones only; through the speaker they'd be lost.
        utterance.volume = Float(request.volume < 1 && !Self.isUsingHeadphones ? 1 : request.volume)
        let id = ObjectIdentifier(utterance)
        recentUtterances.append(utterance)
        if recentUtterances.count > 6 { recentUtterances.removeFirst(recentUtterances.count - 6) }
        let expected = Self.expectedDuration(of: request)
        VoiceLog.add("say \(request.language == .japanese ? "ja" : "en"): \(request.text.prefix(50))")

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                self.continuation = continuation
                self.currentUtterance = id
                self.started = false
                self.synthesizer.speak(utterance)
                self.watch(id, expected: expected)
            }
        } onCancel: {
            Task { @MainActor in self.finishCurrent(stop: true, outcome: .cancelled) }
        }
    }

    /// Ends the utterance if it never starts (`SpeechGuard.startTimeout`) or runs far beyond its expected length.
    private func watch(_ id: ObjectIdentifier, expected: TimeInterval) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(SpeechGuard.startTimeout * 1_000_000_000))
            guard let self, self.currentUtterance == id else { return }
            if !self.started {
                self.finishCurrent(stop: true, outcome: .neverStarted)
                return
            }
            try? await Task.sleep(nanoseconds: UInt64((expected * 2 + 4) * 1_000_000_000))
            guard self.currentUtterance == id else { return }
            self.finishCurrent(stop: true, outcome: .stalled)
        }
    }

    /// "never started within 2.0 s" / "ended after 0.05 s of an expected 2.3 s (no sound)", for the voice log.
    private static func describe(_ verdict: SpeechGuard.Verdict, elapsed: TimeInterval, request: SpeechRequest) -> String {
        switch verdict {
        case .spoken:
            return "spoken"
        case .neverStarted:
            return String(format: "never started within %.1f s", SpeechGuard.startTimeout)
        case .tooFast:
            return String(format: "ended after %.2f s of an expected %.1f s (no sound)", elapsed,
                          SpeechGuard.expectedSpeakingTime(of: request))
        }
    }

    /// Where the sound is going ("Speaker", "BluetoothA2DPOutput"), so a silence in the log can be explained.
    private static var routeDescription: String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue)
        return outputs.isEmpty ? "no audio output" : outputs.joined(separator: ",")
    }

    /// AVSpeechSynthesizer.stopSpeaking can block for seconds on some devices, so it never runs on the main
    /// thread: the synthesizer in use is stopped in the background and a fresh one takes over.
    private func resetSynthesizer() {
        let old = synthesizer
        old.delegate = nil
        synthesizer = AVSpeechSynthesizer()
        configure(synthesizer)
        Self.stopQueue.async { old.stopSpeaking(at: .immediate) }
    }

    private static let stopQueue = DispatchQueue(label: "hanaseru.speech-stop", qos: .userInitiated)

    private func finishCurrent(stop: Bool, outcome: Outcome) {
        if stop && synthesizer.isSpeaking {
            VoiceLog.add("speech stopped")
            resetSynthesizer()
        }
        currentUtterance = nil
        continuation?.resume(returning: outcome)
        continuation = nil
    }

    fileprivate func utteranceStarted(_ id: ObjectIdentifier) {
        if id == currentUtterance { started = true }
    }

    fileprivate func utteranceEnded(_ id: ObjectIdentifier) {
        guard id == currentUtterance else { return }
        finishCurrent(stop: false, outcome: .finished)
    }

    /// A generous estimate of how long an utterance takes, for the watchdog.
    static func expectedDuration(of request: SpeechRequest) -> TimeInterval {
        let charactersPerSecond = request.language == .japanese ? 6.0 : 12.0
        return Double(request.text.count) / charactersPerSecond / max(request.rate, 0.5) + request.pauseAfter
    }

    // MARK: - Voices

    private static var voiceCache: [String: AVSpeechSynthesisVoice] = [:]

    /// The voice for a language: the one chosen in Settings, otherwise the most natural one installed.
    static func voice(for language: SpeechLanguage) -> AVSpeechSynthesisVoice? {
        let key = language == .japanese ? SettingsKey.japaneseVoice : SettingsKey.englishVoice
        let choice = UserDefaults.standard.string(forKey: key) ?? ""
        let cacheKey = "\(language)|\(choice)"
        if let cached = voiceCache[cacheKey] { return cached }
        let voice = AVSpeechSynthesisVoice(identifier: choice)
            ?? bestVoice(for: language, preferredLocale: choice.hasPrefix("en-") ? choice : nil)
            ?? AVSpeechSynthesisVoice(language: language == .japanese ? "ja-JP" : "en-US")
        voiceCache[cacheKey] = voice
        return voice
    }

    /// Installed voices for a language, without novelty voices or the learner's Personal Voice.
    static func candidates(for language: SpeechLanguage) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { voice in
            let matches = language == .japanese ? voice.language == "ja-JP" : voice.language.hasPrefix("en")
            return matches && !voice.voiceTraits.contains(.isNoveltyVoice)
                && !voice.voiceTraits.contains(.isPersonalVoice)
                && !voice.identifier.lowercased().contains("eloquence")
        }
    }

    /// Quality first (Premium, Enhanced, then default), then accent: the preferred one, then Indian, British, US.
    static func bestVoice(for language: SpeechLanguage, preferredLocale: String? = nil) -> AVSpeechSynthesisVoice? {
        let accents = ["en-IN", "en-GB", "en-US", "en-AU", "en-IE", "en-ZA"]
        func rank(_ voice: AVSpeechSynthesisVoice) -> (Int, Int) {
            let accent = voice.language == preferredLocale ? 100 : 50 - (accents.firstIndex(of: voice.language) ?? 40)
            return (voice.quality.rawValue, accent)
        }
        return candidates(for: language).max { rank($0) < rank($1) }
    }

    /// The voice for a speaking role. The partner gets a different Japanese voice of their gender when one is
    /// installed; otherwise the coach's voice with a pitch shift, so the two can be told apart by ear.
    static func voice(for role: VoiceRole, language: SpeechLanguage) -> (voice: AVSpeechSynthesisVoice?, pitch: Float) {
        switch role {
        case .coachEnglish:
            return (voice(for: .english), 1.0)
        case .coachJapanese:
            return (voice(for: language), 1.0)
        case .partner(let gender):
            let coach = voice(for: .japanese)
            // Another quality of the coach's own speaker ("Kyoko" vs "Kyoko (Enhanced)") would sound the same.
            let coachSpeaker = coach.map(speakerName)
            let others = candidates(for: .japanese).filter {
                $0.identifier != coach?.identifier && speakerName($0) != coachSpeaker
            }
            let wanted: AVSpeechSynthesisVoiceGender? = switch gender {
            case .male?: .male
            case .female?: .female
            case nil: nil
            }
            let match = others
                .filter { wanted == nil || $0.gender == wanted }
                .max { $0.quality.rawValue < $1.quality.rawValue }
            if let match { return (match, 1.0) }
            // Only one Japanese voice installed: shift its pitch for the partner.
            let pitch: Float = gender == .female ? 1.12 : 0.88
            return (coach, pitch)
        }
    }

    /// The speaker behind a voice, without its quality suffix: "Kyoko (Enhanced)" → "Kyoko".
    private static func speakerName(_ voice: AVSpeechSynthesisVoice) -> String {
        let base = voice.name.components(separatedBy: CharacterSet(charactersIn: "(（")).first ?? voice.name
        return base.trimmingCharacters(in: .whitespaces)
    }

    static var isUsingHeadphones: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { output in
            [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains(output.portType)
        }
    }

    /// Maps a speed multiple (0.75×, 1×, 1.25×, 1.5×) onto AVSpeech's non-linear rate scale.
    static func rate(for multiple: Double) -> Float {
        let base = Double(AVSpeechUtteranceDefaultSpeechRate)
        let rate = base + (multiple - 1) * 0.25
        return Float(min(max(rate, 0.35), 0.62))
    }

    static func resetVoiceCache() {
        voiceCache.removeAll()
    }

    static func qualityName(_ voice: AVSpeechSynthesisVoice?) -> String {
        switch voice?.quality {
        case .premium?: "Premium"
        case .enhanced?: "Enhanced"
        case .some: "Basic"
        case nil: "Not installed"
        }
    }

    /// Quality of the Japanese voice in use, shown in Settings.
    static var japaneseVoiceQuality: String { qualityName(voice(for: .japanese)) }

    /// True when only a basic (robotic-sounding) English voice is installed.
    static var englishVoiceIsBasic: Bool {
        (voice(for: .english)?.quality ?? .default) == .default
    }
}

// Callbacks reach the main actor through the main queue, which keeps their order: the start of an utterance is
// always seen before its end (separate tasks don't promise that).
extension AppleSpeechSynthesisProvider: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.utteranceStarted(id) } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.utteranceEnded(id) } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.utteranceEnded(id) } }
    }
}

/// Speaks a sample in Settings, outside a session.
@MainActor
final class VoicePreview {
    static let shared = VoicePreview()
    private let synthesizer: AVSpeechSynthesizer = {
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.usesApplicationAudioSession = false
        return synthesizer
    }()

    func play(_ text: String, voice: AVSpeechSynthesisVoice?, rate: Double = 1, pitch: Float = 1) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AppleSpeechSynthesisProvider.rate(for: rate)
        utterance.pitchMultiplier = pitch
        synthesizer.speak(utterance)
    }
}
