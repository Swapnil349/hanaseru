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

/// What the learner is being asked to say right now — drives the cue card and the lock screen.
public struct FocusInfo: Equatable, Sendable {
    public var lineID: String
    public var level: ScaffoldLevel
    /// The cue as spoken, e.g. "Say: No, there's no particular problem." or the intent at S3.
    public var cueEn: String
    /// The line's English meaning (always available on screen while the line is new or guided).
    public var english: String
    public var japanese: String
    public var kana: String
    /// Japanese shown before the answer: everything at S0, the first chunk at S1, nothing from S2.
    public var visibleJapanese: String
    /// Placeholder circles for the hidden part at S1 (○○○), sized to the missing morae.
    public var hiddenPlaceholder: String
    public var partnerJapanese: String
    public var partnerEnglish: String
    public var partnerName: String
    /// Card heading when it isn't the learner's own line ("LISTEN"); empty for LEARN / YOUR LINE.
    public var heading: String

    public init(lineID: String, level: ScaffoldLevel, cueEn: String, english: String, japanese: String, kana: String,
                visibleJapanese: String, hiddenPlaceholder: String = "", partnerJapanese: String = "",
                partnerEnglish: String = "", partnerName: String = "", heading: String = "") {
        self.lineID = lineID
        self.level = level
        self.cueEn = cueEn
        self.english = english
        self.japanese = japanese
        self.kana = kana
        self.visibleJapanese = visibleJapanese
        self.hiddenPlaceholder = hiddenPlaceholder
        self.partnerJapanese = partnerJapanese
        self.partnerEnglish = partnerEnglish
        self.partnerName = partnerName
        self.heading = heading
    }
}

/// The answer, shown after every turn: what was right, what was heard. Never "wrong".
public struct RevealInfo: Equatable, Sendable {
    public var lineID: String
    public var japanese: String
    public var kana: String
    public var english: String
    public var heard: String
    public var outcome: TurnOutcome
    public var matchedChunks: [String]
    public var missingChunks: [String]
    public var note: String

    public init(lineID: String, japanese: String, kana: String, english: String, heard: String, outcome: TurnOutcome,
                matchedChunks: [String] = [], missingChunks: [String] = [], note: String = "") {
        self.lineID = lineID
        self.japanese = japanese
        self.kana = kana
        self.english = english
        self.heard = heard
        self.outcome = outcome
        self.matchedChunks = matchedChunks
        self.missingChunks = missingChunks
        self.note = note
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
    /// The line now being taught or asked for.
    case focus(FocusInfo)
    /// The answer after a turn.
    case reveal(RevealInfo)
    /// The learner's think time for this listen, and when the nudge will come (0 = none).
    case turnWindow(seconds: Double, nudgeAt: Double)
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
