import Foundation
import LearningCore

public enum LineRole: Equatable, Sendable {
    /// Coach instruction or cue (聞いてください。 etc.)
    case coach
    /// Role-play partner or the voice in a listening item.
    case partner(name: String)
    case learner
    /// On-screen-only context: the English task, a revealed transcript.
    case instruction
}

public struct ScriptLine: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var role: LineRole
    public var japanese: String
    public var kana: String
    public var english: String

    public init(role: LineRole, japanese: String, kana: String = "", english: String = "") {
        self.id = UUID()
        self.role = role
        self.japanese = japanese
        self.kana = kana
        self.english = english
    }
}

public struct FeedbackNote: Equatable, Sendable {
    public var verdict: ResponseVerdict
    /// Short English headline for the screen.
    public var headline: String
    /// Optional English explanation.
    public var detail: String
    /// Japanese suggestion (model answer or more natural version).
    public var suggestion: String
    /// What the recogniser heard.
    public var heard: String

    public init(verdict: ResponseVerdict, headline: String, detail: String = "", suggestion: String = "", heard: String = "") {
        self.verdict = verdict
        self.headline = headline
        self.detail = detail
        self.suggestion = suggestion
        self.heard = heard
    }
}

public enum SessionActivity: Equatable, Sendable {
    case preparing
    /// The coach or partner is talking.
    case speaking
    /// The learner's turn: the recogniser is transcribing.
    case listening
    /// Evaluating or waiting for the AI.
    case thinking
    case paused
    case finished
}

public enum SessionEvent: Equatable, Sendable {
    case activity(SessionActivity)
    case exerciseStarted(index: Int, total: Int, kind: ExerciseKind, title: String)
    case line(ScriptLine)
    case partialTranscript(String)
    case feedback(FeedbackNote)
    /// True while the AI coach is unreachable and the offline engine is standing in.
    case aiDegraded(Bool)
    case finished(SessionSummary)
}

public struct SessionSummary: Equatable, Sendable {
    public var startedAt: Date
    public var endedAt: Date
    public var plannedMinutes: Int
    public var focus: SessionFocus
    /// Seconds of Japanese the learner heard.
    public var secondsListening: Double
    /// Seconds the learner spoke.
    public var secondsSpeaking: Double
    public var results: [ExerciseResult]
    public var conversationTurns: Int
    public var scenarioIDs: [String]
    public var mistakes: [MistakeObservation]
    public var wentWell: [String]
    public var toPractise: [String]
    public var phraseID: String?
    public var phraseJapanese: String
    public var phraseEnglish: String
    public var completedNormally: Bool

    public init(startedAt: Date, endedAt: Date, plannedMinutes: Int, focus: SessionFocus, secondsListening: Double,
                secondsSpeaking: Double, results: [ExerciseResult], conversationTurns: Int, scenarioIDs: [String],
                mistakes: [MistakeObservation], wentWell: [String], toPractise: [String], phraseID: String?,
                phraseJapanese: String, phraseEnglish: String, completedNormally: Bool) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.plannedMinutes = plannedMinutes
        self.focus = focus
        self.secondsListening = secondsListening
        self.secondsSpeaking = secondsSpeaking
        self.results = results
        self.conversationTurns = conversationTurns
        self.scenarioIDs = scenarioIDs
        self.mistakes = mistakes
        self.wentWell = wentWell
        self.toPractise = toPractise
        self.phraseID = phraseID
        self.phraseJapanese = phraseJapanese
        self.phraseEnglish = phraseEnglish
        self.completedNormally = completedNormally
    }

    public var exercisesCompleted: Int { results.count }
    public var durationSeconds: Double { endedAt.timeIntervalSince(startedAt) }
}
