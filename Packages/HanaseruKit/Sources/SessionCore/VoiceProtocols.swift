import Foundation

/// Voice-engine abstractions (spec §35, §55 layer 3). The session logic depends only on these;
/// the iOS app provides AVFoundation/Speech implementations and tests provide scripted fakes.

public enum SpeechLanguage: String, Sendable {
    case japanese
    case english
}

public struct SpeechRequest: Equatable, Sendable {
    public var text: String
    public var language: SpeechLanguage
    /// Multiple of natural speed: 0.75, 1.0, 1.25, 1.5 (spec §37).
    public var rate: Double
    /// Silence after the utterance, in seconds.
    public var pauseAfter: TimeInterval

    public init(text: String, language: SpeechLanguage, rate: Double = 1.0, pauseAfter: TimeInterval = 0.15) {
        self.text = text
        self.language = language
        self.rate = rate
        self.pauseAfter = pauseAfter
    }
}

@MainActor
public protocol SpeechSynthesisProvider: AnyObject {
    /// Speaks and returns when finished, or immediately when the calling task is cancelled.
    func speak(_ request: SpeechRequest) async
    func stopSpeaking()
}

public struct ListenOptions: Equatable, Sendable {
    /// Give up if the learner hasn't started speaking after this long.
    public var startTimeout: TimeInterval
    /// Treat this much silence after speech as the end of the learner's turn (no button press needed).
    public var endSilence: TimeInterval
    public var maxDuration: TimeInterval
    /// Words likely to be said, to bias recognition (e.g. 進捗, 橋脚).
    public var contextualStrings: [String]

    public init(startTimeout: TimeInterval = 10, endSilence: TimeInterval = 1.4, maxDuration: TimeInterval = 25, contextualStrings: [String] = []) {
        self.startTimeout = startTimeout
        self.endSilence = endSilence
        self.maxDuration = maxDuration
        self.contextualStrings = contextualStrings
    }
}

public enum ListenOutcome: Equatable, Sendable {
    case speech
    case noSpeech
    case failed(String)
}

public struct ListenResult: Equatable, Sendable {
    public var transcript: String
    /// 0...1 when the recogniser provides it.
    public var confidence: Double?
    /// Seconds from the start of listening until speech was first detected (spec §79).
    public var latency: TimeInterval?
    /// Seconds of learner speech.
    public var speakingDuration: TimeInterval
    public var outcome: ListenOutcome

    public init(transcript: String, confidence: Double? = nil, latency: TimeInterval? = nil, speakingDuration: TimeInterval = 0, outcome: ListenOutcome) {
        self.transcript = transcript
        self.confidence = confidence
        self.latency = latency
        self.speakingDuration = speakingDuration
        self.outcome = outcome
    }

    public static let silence = ListenResult(transcript: "", outcome: .noSpeech)
}

/// Replaceable speech recogniser (spec §35).
@MainActor
public protocol SpeechRecognitionProvider: AnyObject {
    /// Where audio is processed, for the privacy indicator (spec §60), e.g. "on this iPhone".
    var processingDescription: String { get }
    /// Listens for one learner turn. Must return promptly when the calling task is cancelled.
    func listen(_ options: ListenOptions, onPartial: @escaping @MainActor (String) -> Void) async -> ListenResult
    func cancelListening()
}

public enum HapticCue: Sendable {
    case yourTurn
    case correct
    case tryAgain
    case sessionComplete
}

/// Haptics and non-speech sounds (spec §51). Kept subtle.
@MainActor
public protocol CueFeedbackProvider: AnyObject {
    func play(_ cue: HapticCue)
}
