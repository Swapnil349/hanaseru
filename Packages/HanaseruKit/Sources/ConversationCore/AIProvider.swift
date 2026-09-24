import Foundation
import LearningCore

// MARK: - Conversation DTOs
// These types are also the wire format of the coach proxy (backend/), so keep field names in sync
// with backend/src/schemas.ts.

public enum Speaker: String, Codable, Sendable {
    case partner
    case learner
}

public struct DialogueTurn: Codable, Equatable, Sendable {
    public var speaker: Speaker
    public var japanese: String
    public var english: String?

    public init(speaker: Speaker, japanese: String, english: String? = nil) {
        self.speaker = speaker
        self.japanese = japanese
        self.english = english
    }
}

public struct PersonaBrief: Codable, Equatable, Sendable {
    public var name: String
    public var role: String
    public var personality: String
    public var formality: Politeness
    public var style: String

    public init(name: String, role: String, personality: String, formality: Politeness, style: String) {
        self.name = name
        self.role = role
        self.personality = personality
        self.formality = formality
        self.style = style
    }

    public init(_ persona: Persona) {
        self.init(name: persona.nameJa, role: persona.role, personality: persona.personality,
                  formality: persona.formality, style: persona.style)
    }
}

/// Everything the conversation engine needs to take the next turn. The full history is sent each turn,
/// which gives the AI in-session conversational memory (spec §28).
public struct ConversationContext: Codable, Equatable, Sendable {
    public var scenarioID: String
    public var scenarioTitle: String
    public var situation: String
    public var persona: PersonaBrief
    public var learnerName: String
    public var learnerLevel: Int
    public var englishSupport: Double
    /// Japanese words the scenario wants to recur (spec §4).
    public var targetTerms: [String]
    /// Mistake types the learner often makes, so the AI can create natural chances to practise them.
    public var recurringMistakeTypes: [String]
    public var history: [DialogueTurn]
    /// Index of the partner line the learner is answering (0-based).
    public var turnIndex: Int
    public var maxTurns: Int

    public init(scenarioID: String, scenarioTitle: String, situation: String, persona: PersonaBrief, learnerName: String,
                learnerLevel: Int, englishSupport: Double, targetTerms: [String], recurringMistakeTypes: [String],
                history: [DialogueTurn], turnIndex: Int, maxTurns: Int) {
        self.scenarioID = scenarioID
        self.scenarioTitle = scenarioTitle
        self.situation = situation
        self.persona = persona
        self.learnerName = learnerName
        self.learnerLevel = learnerLevel
        self.englishSupport = englishSupport
        self.targetTerms = targetTerms
        self.recurringMistakeTypes = recurringMistakeTypes
        self.history = history
        self.turnIndex = turnIndex
        self.maxTurns = maxTurns
    }
}

public struct TurnRequest: Codable, Equatable, Sendable {
    public var context: ConversationContext
    public var learnerUtterance: String
    public var asrConfidence: Double?

    public init(context: ConversationContext, learnerUtterance: String, asrConfidence: Double? = nil) {
        self.context = context
        self.learnerUtterance = learnerUtterance
        self.asrConfidence = asrConfidence
    }
}

public struct DetectedMistake: Codable, Equatable, Sendable {
    public var type: MistakeType
    public var said: String
    public var correction: String
    public var explanation: String

    public init(type: MistakeType, said: String, correction: String, explanation: String) {
        self.type = type
        self.said = said
        self.correction = correction
        self.explanation = explanation
    }
}

public struct TurnEvaluation: Codable, Equatable, Sendable {
    public var verdict: ResponseVerdict
    /// Would a Japanese colleague have understood the learner?
    public var understood: Bool
    /// Short, encouraging English note. Empty when nothing needs saying.
    public var feedbackEn: String
    /// How a Japanese colleague would naturally say what the learner meant. Empty when already natural.
    public var naturalVersion: String
    public var mistakes: [DetectedMistake]

    public init(verdict: ResponseVerdict, understood: Bool, feedbackEn: String = "", naturalVersion: String = "", mistakes: [DetectedMistake] = []) {
        self.verdict = verdict
        self.understood = understood
        self.feedbackEn = feedbackEn
        self.naturalVersion = naturalVersion
        self.mistakes = mistakes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        verdict = try c.decode(ResponseVerdict.self, forKey: .verdict)
        understood = try c.decodeIfPresent(Bool.self, forKey: .understood) ?? verdict.communicated
        feedbackEn = try c.decodeIfPresent(String.self, forKey: .feedbackEn) ?? ""
        naturalVersion = try c.decodeIfPresent(String.self, forKey: .naturalVersion) ?? ""
        mistakes = try c.decodeIfPresent([DetectedMistake].self, forKey: .mistakes) ?? []
    }

    /// Wraps an offline evaluation. The model answer becomes the suggestion whenever the answer wasn't natural.
    public init(local: LocalEvaluation, said: String) {
        let showModel = local.verdict != .natural && !local.modelAnswer.isEmpty
        self.init(
            verdict: local.verdict,
            understood: local.verdict.communicated,
            feedbackEn: local.matchedMistakes.first?.explanation ?? "",
            naturalVersion: showModel ? local.modelAnswer : "",
            mistakes: local.matchedMistakes.map {
                DetectedMistake(type: $0.type, said: said, correction: $0.correction, explanation: $0.explanation)
            }
        )
    }
}

public struct CoachLine: Codable, Equatable, Sendable {
    public var japanese: String
    public var kana: String
    public var english: String

    public init(japanese: String, kana: String = "", english: String = "") {
        self.japanese = japanese
        self.kana = kana
        self.english = english
    }
}

public struct TurnResponse: Codable, Equatable, Sendable {
    public var evaluation: TurnEvaluation
    public var reply: CoachLine
    /// The partner has wrapped up the conversation.
    public var shouldEnd: Bool

    public init(evaluation: TurnEvaluation, reply: CoachLine, shouldEnd: Bool) {
        self.evaluation = evaluation
        self.reply = reply
        self.shouldEnd = shouldEnd
    }
}

public enum EvaluationMode: String, Codable, Sendable {
    /// "How would you say this naturally?" (spec §80)
    case recall
    /// Answer to a comprehension question (spec §81)
    case listening
}

public struct EvaluationRequest: Codable, Equatable, Sendable {
    public var mode: EvaluationMode
    /// The English concept (recall) or the heard sentence (listening).
    public var prompt: String
    /// The comprehension question, for listening mode.
    public var question: String
    /// Example correct answers — not the only correct answers.
    public var examples: [String]
    public var learnerUtterance: String
    public var learnerLevel: Int
    public var politeness: Politeness

    public init(mode: EvaluationMode, prompt: String, question: String = "", examples: [String], learnerUtterance: String,
                learnerLevel: Int, politeness: Politeness = .professional) {
        self.mode = mode
        self.prompt = prompt
        self.question = question
        self.examples = examples
        self.learnerUtterance = learnerUtterance
        self.learnerLevel = learnerLevel
        self.politeness = politeness
    }
}

// Requests for capabilities planned for later milestones (declared now so providers share one surface).
public struct ExerciseRequest: Codable, Sendable {
    public var track: Track
    public var level: Int
    public var focusTerms: [String]
    public var kind: ExerciseKind
}

public struct ScenarioRequest: Codable, Sendable {
    public var topic: String
    public var track: Track
    public var level: Int
    public var personaID: String?
    public var mustUse: [String]
}

public struct GrammarRequest: Codable, Sendable {
    public var sentence: String
    public var question: String
}

public struct GrammarExplanation: Codable, Equatable, Sendable {
    public var summary: String
    public var whenUsed: String
    public var examples: [String]
}

public struct ReviewRequest: Codable, Sendable {
    public var results: [ExerciseResult]
    public var mistakes: [MistakeObservation]
}

public struct SessionReview: Codable, Equatable, Sendable {
    public var wentWell: [String]
    public var struggledWith: [String]
    public var phrasesToPractise: [String]
    public var grammarToReview: String
}

public struct DifficultyRequest: Codable, Sendable {
    public var current: DifficultyProfile
    public var recent: [ExerciseResult]
}

public enum AIProviderError: Error, Equatable, Sendable {
    case notAvailable(String)
    case unknownScenario(String)
    case transport(String)
    case badResponse(String)
    case timedOut
}

/// The conversation engine's single AI surface (spec §54). Providers are swappable.
public protocol AIProvider: Sendable {
    /// Short label for UI ("Claude", "Offline").
    var name: String { get }
    func generateResponse(_ request: TurnRequest) async throws -> TurnResponse
    func evaluateResponse(_ request: EvaluationRequest) async throws -> TurnEvaluation
    func generateExercise(_ request: ExerciseRequest) async throws -> LearningItem
    func generateScenario(_ request: ScenarioRequest) async throws -> Scenario
    func explainGrammar(_ request: GrammarRequest) async throws -> GrammarExplanation
    func generateReview(_ request: ReviewRequest) async throws -> SessionReview
    func adaptDifficulty(_ request: DifficultyRequest) async throws -> DifficultyProfile
}

public extension AIProvider {
    func generateExercise(_ request: ExerciseRequest) async throws -> LearningItem {
        throw AIProviderError.notAvailable("generateExercise")
    }

    func generateScenario(_ request: ScenarioRequest) async throws -> Scenario {
        throw AIProviderError.notAvailable("generateScenario")
    }

    func explainGrammar(_ request: GrammarRequest) async throws -> GrammarExplanation {
        throw AIProviderError.notAvailable("explainGrammar")
    }

    func generateReview(_ request: ReviewRequest) async throws -> SessionReview {
        throw AIProviderError.notAvailable("generateReview")
    }

    func adaptDifficulty(_ request: DifficultyRequest) async throws -> DifficultyProfile {
        DifficultyAdapter().adapted(request.current, recent: request.recent)
    }
}
