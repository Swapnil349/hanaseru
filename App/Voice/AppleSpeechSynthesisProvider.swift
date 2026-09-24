import AVFoundation
import SessionCore

/// Japanese and English speech via `AVSpeechSynthesizer` (spec §61).
///
/// Picks the best installed Japanese voice. Download "Japanese — Premium" or "Enhanced" in
/// Settings › Accessibility › Spoken Content › Voices for noticeably more natural speech.
@MainActor
final class AppleSpeechSynthesisProvider: NSObject, SpeechSynthesisProvider {
    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?
    private var currentUtterance: ObjectIdentifier?

    override init() {
        super.init()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = true
    }

    func speak(_ request: SpeechRequest) async {
        guard !Task.isCancelled, !request.text.isEmpty else { return }
        finishCurrent(stop: true)

        let utterance = AVSpeechUtterance(string: request.text)
        utterance.voice = Self.voice(for: request.language)
        utterance.rate = Self.rate(for: request.rate)
        utterance.postUtteranceDelay = request.pauseAfter
        let id = ObjectIdentifier(utterance)

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.continuation = continuation
                self.currentUtterance = id
                self.synthesizer.speak(utterance)
            }
        } onCancel: {
            Task { @MainActor in self.finishCurrent(stop: true) }
        }
    }

    func stopSpeaking() {
        finishCurrent(stop: true)
    }

    private func finishCurrent(stop: Bool) {
        if stop && synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        currentUtterance = nil
        continuation?.resume()
        continuation = nil
    }

    fileprivate func utteranceEnded(_ id: ObjectIdentifier) {
        guard id == currentUtterance else { return }
        finishCurrent(stop: false)
    }

    // MARK: - Voices

    private static var voiceCache: [String: AVSpeechSynthesisVoice] = [:]

    static func voice(for language: SpeechLanguage) -> AVSpeechSynthesisVoice? {
        let code: String
        switch language {
        case .japanese: code = "ja-JP"
        case .english: code = UserDefaults.standard.string(forKey: SettingsKey.englishVoice) ?? "en-IN"
        }
        if let cached = voiceCache[code] { return cached }
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == code }
        let best = candidates.max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: code)
            ?? (language == .english ? AVSpeechSynthesisVoice(language: "en-US") : nil)
        voiceCache[code] = best
        return best
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

    /// Quality of the installed Japanese voice, shown in Settings.
    static var japaneseVoiceQuality: String {
        switch voice(for: .japanese)?.quality {
        case .premium?: "Premium"
        case .enhanced?: "Enhanced"
        case .some: "Default"
        case nil: "Not installed"
        }
    }
}

extension AppleSpeechSynthesisProvider: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceEnded(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceEnded(id) }
    }
}
