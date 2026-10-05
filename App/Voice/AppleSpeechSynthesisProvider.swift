import AVFoundation
import LearningCore
import SessionCore

/// Japanese and English speech via `AVSpeechSynthesizer` (spec §61).
///
/// Picks the most natural installed voice (Premium, then Enhanced) unless the learner chose one in Settings.
/// Download "Premium" or "Enhanced" voices in iOS Settings › Accessibility › Spoken Content › Voices.
///
/// A watchdog guards every utterance: iOS occasionally drops an utterance (right after a stop, or when the
/// audio route changes) without ever reporting that it finished. Without the watchdog the session would wait
/// in silence forever; with it, the utterance is retried once on a fresh synthesizer and the session goes on.
@MainActor
final class AppleSpeechSynthesisProvider: NSObject, SpeechSynthesisProvider {
    private enum Outcome {
        case finished, cancelled, neverStarted, stalled
    }

    private var synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var currentUtterance: ObjectIdentifier?
    private var started = false
    /// Plays the pre-recorded natural English (nil: always the iOS voice).
    private let engine: AudioEngineHost?

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
            switch await speakOnce(request) {
            case .finished, .cancelled:
                return
            case .neverStarted:
                VoiceLog.add("speech never started (try \(attempt)): \(request.text.prefix(40))")
                resetSynthesizer()
            case .stalled:
                VoiceLog.add("speech stalled, skipped: \(request.text.prefix(40))")
                resetSynthesizer()
                return
            }
        }
    }

    func stopSpeaking() {
        engine?.stopClip()
        finishCurrent(stop: true, outcome: .cancelled)
    }

    /// The natural pre-recorded English, when every part of the sentence was recorded. False: use iOS speech.
    private func speakRecorded(_ request: SpeechRequest) async -> Bool {
        guard NaturalEnglishVoice.isEnabled, let engine, engine.isRunning,
              let clips = NaturalEnglishVoice.shared.recordings(for: request.text), !clips.isEmpty else {
            if NaturalEnglishVoice.shared.isAvailable { VoiceLog.add("not recorded, iPhone voice: \(request.text.prefix(50))") }
            return false
        }
        finishCurrent(stop: true, outcome: .cancelled)
        VoiceLog.add("say en (natural): \(request.text.prefix(50))")
        let volume = Float(request.volume < 1 && !Self.isUsingHeadphones ? 1 : request.volume)
        for clip in clips {
            guard !Task.isCancelled else { return true }
            let played = await withTaskCancellationHandler {
                await engine.playClip(clip, volume: volume)
            } onCancel: {
                engine.stopClip()
            }
            if !played { return false }
        }
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

    /// Ends the utterance if it never starts (4 s) or runs far beyond its expected length.
    private func watch(_ id: ObjectIdentifier, expected: TimeInterval) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
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

    private func resetSynthesizer() {
        synthesizer.delegate = nil
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer = AVSpeechSynthesizer()
        configure(synthesizer)
    }

    private func finishCurrent(stop: Bool, outcome: Outcome) {
        if stop && synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
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

extension AppleSpeechSynthesisProvider: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceStarted(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceEnded(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceEnded(id) }
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

    func play(_ text: String, voice: AVSpeechSynthesisVoice?) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        synthesizer.speak(utterance)
    }
}
