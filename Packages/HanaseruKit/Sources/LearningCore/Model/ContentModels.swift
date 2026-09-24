import Foundation

/// The two parallel learning tracks (spec §3, §19).
public enum Track: String, Codable, CaseIterable, Sendable {
    case work
    case everyday
}

/// Register of an expression (spec §12).
public enum Politeness: String, Codable, CaseIterable, Sendable {
    case casual
    case professional
    case veryPolite
}

public enum ItemKind: String, Codable, Sendable {
    case word
    case phrase
    case sentence
    case question
}

/// A set of interchangeable spellings. A response "contains" the group when it contains any of them.
/// Groups usually list the kanji form and the kana form, because speech recognition may return either.
public struct KeyTermGroup: Codable, Hashable, Sendable {
    public var anyOf: [String]

    public init(_ anyOf: [String]) {
        self.anyOf = anyOf
    }

    public init(from decoder: Decoder) throws {
        // Accept both `["進捗", "しんちょく"]` and `{ "anyOf": [...] }` in content files.
        if let list = try? decoder.singleValueContainer().decode([String].self) {
            anyOf = list
        } else {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            anyOf = try container.decode([String].self, forKey: .anyOf)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(anyOf)
    }

    private enum CodingKeys: String, CodingKey { case anyOf }
}

public enum MistakeType: String, Codable, CaseIterable, Sendable {
    case pastTense
    case conjugation
    case particle
    case politeness
    case vocabulary
    case wordOrder
    case other

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MistakeType(rawValue: raw) ?? .other
    }

    public var displayName: String {
        switch self {
        case .pastTense: "Past tense"
        case .conjugation: "Conjugation"
        case .particle: "Particles"
        case .politeness: "Politeness"
        case .vocabulary: "Word choice"
        case .wordOrder: "Word order"
        case .other: "Other"
        }
    }
}

/// A known, predictable error for an item, e.g. using 行きます with 昨日 (spec §30).
public struct MistakePattern: Codable, Hashable, Sendable {
    public var id: String
    public var type: MistakeType
    /// Every group must be present in the response for the pattern to match.
    public var whenContainsAll: [KeyTermGroup]
    /// If any of these is present, the pattern does not match (e.g. the correct form was also said).
    public var unlessContainsAny: [String]
    public var correction: String
    public var explanation: String

    public init(id: String, type: MistakeType, whenContainsAll: [KeyTermGroup], unlessContainsAny: [String] = [], correction: String, explanation: String) {
        self.id = id
        self.type = type
        self.whenContainsAll = whenContainsAll
        self.unlessContainsAny = unlessContainsAny
        self.correction = correction
        self.explanation = explanation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(MistakeType.self, forKey: .type)
        whenContainsAll = try c.decode([KeyTermGroup].self, forKey: .whenContainsAll)
        unlessContainsAny = try c.decodeIfPresent([String].self, forKey: .unlessContainsAny) ?? []
        correction = try c.decode(String.self, forKey: .correction)
        explanation = try c.decode(String.self, forKey: .explanation)
    }

    public func matches(_ response: String) -> Bool {
        guard !whenContainsAll.isEmpty else { return false }
        let hit = whenContainsAll.allSatisfy { JapaneseText.contains(response, anyOf: $0.anyOf) }
        return hit && !JapaneseText.contains(response, anyOf: unlessContainsAny)
    }
}

/// A comprehension question asked after the learner hears the item ("What did they say?", spec §81).
public struct ListeningCheck: Codable, Hashable, Sendable {
    public var questionJa: String
    public var questionEn: String
    public var answerTerms: [KeyTermGroup]
    public var modelAnswer: String

    public init(questionJa: String, questionEn: String, answerTerms: [KeyTermGroup], modelAnswer: String) {
        self.questionJa = questionJa
        self.questionEn = questionEn
        self.answerTerms = answerTerms
        self.modelAnswer = modelAnswer
    }
}

public struct LearningItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var japanese: String
    public var kana: String
    public var romaji: String
    public var english: String
    public var literal: String?
    public var track: Track
    public var category: String
    /// Internal difficulty 1–8 (spec §18). Never shown as a game level.
    public var level: Int
    public var kind: ItemKind
    public var politeness: Politeness
    /// "When would a Japanese professional actually say this?" (spec §11)
    public var usageNote: String?
    public var grammar: [String]
    /// Vocabulary ids this item exercises, so the same words recur in new contexts (spec §4).
    public var terms: [String]
    /// English concept for "How would you say this naturally?" (spec §80). Nil = not a recall item.
    public var promptEn: String?
    public var acceptableResponses: [String]
    public var keyTerms: [KeyTermGroup]
    public var commonMistakes: [MistakePattern]
    public var listening: ListeningCheck?
    public var naturalAlternatives: [String]
    public var isPersonal: Bool

    public init(
        id: String, japanese: String, kana: String, romaji: String = "", english: String,
        literal: String? = nil, track: Track, category: String, level: Int, kind: ItemKind = .phrase,
        politeness: Politeness = .professional, usageNote: String? = nil, grammar: [String] = [],
        terms: [String] = [], promptEn: String? = nil, acceptableResponses: [String] = [],
        keyTerms: [KeyTermGroup] = [], commonMistakes: [MistakePattern] = [],
        listening: ListeningCheck? = nil, naturalAlternatives: [String] = [], isPersonal: Bool = false
    ) {
        self.id = id
        self.japanese = japanese
        self.kana = kana
        self.romaji = romaji
        self.english = english
        self.literal = literal
        self.track = track
        self.category = category
        self.level = level
        self.kind = kind
        self.politeness = politeness
        self.usageNote = usageNote
        self.grammar = grammar
        self.terms = terms
        self.promptEn = promptEn
        self.acceptableResponses = acceptableResponses
        self.keyTerms = keyTerms
        self.commonMistakes = commonMistakes
        self.listening = listening
        self.naturalAlternatives = naturalAlternatives
        self.isPersonal = isPersonal
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        japanese = try c.decode(String.self, forKey: .japanese)
        kana = try c.decode(String.self, forKey: .kana)
        romaji = try c.decodeIfPresent(String.self, forKey: .romaji) ?? ""
        english = try c.decode(String.self, forKey: .english)
        literal = try c.decodeIfPresent(String.self, forKey: .literal)
        track = try c.decode(Track.self, forKey: .track)
        category = try c.decode(String.self, forKey: .category)
        level = try c.decode(Int.self, forKey: .level)
        kind = try c.decodeIfPresent(ItemKind.self, forKey: .kind) ?? .phrase
        politeness = try c.decodeIfPresent(Politeness.self, forKey: .politeness) ?? .professional
        usageNote = try c.decodeIfPresent(String.self, forKey: .usageNote)
        grammar = try c.decodeIfPresent([String].self, forKey: .grammar) ?? []
        terms = try c.decodeIfPresent([String].self, forKey: .terms) ?? []
        promptEn = try c.decodeIfPresent(String.self, forKey: .promptEn)
        acceptableResponses = try c.decodeIfPresent([String].self, forKey: .acceptableResponses) ?? []
        keyTerms = try c.decodeIfPresent([KeyTermGroup].self, forKey: .keyTerms) ?? []
        commonMistakes = try c.decodeIfPresent([MistakePattern].self, forKey: .commonMistakes) ?? []
        listening = try c.decodeIfPresent(ListeningCheck.self, forKey: .listening)
        naturalAlternatives = try c.decodeIfPresent([String].self, forKey: .naturalAlternatives) ?? []
        isPersonal = try c.decodeIfPresent(Bool.self, forKey: .isPersonal) ?? false
    }

    /// Everything a learner could reasonably say for this item, used as the reference set for evaluation.
    public var referenceResponses: [String] {
        var all = acceptableResponses
        if !all.contains(japanese) { all.insert(japanese, at: 0) }
        if !kana.isEmpty && !all.contains(kana) { all.append(kana) }
        return all
    }

    public var supportsRecall: Bool { promptEn != nil }
    public var supportsListening: Bool { listening != nil }
}

public struct VocabularyExample: Codable, Hashable, Sendable {
    public var ja: String
    public var kana: String
    public var en: String
}

/// An entry in the professional / railway corpus (spec §5).
public struct VocabularyTerm: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var japanese: String
    public var kana: String
    public var romaji: String
    public var english: String
    public var categories: [String]
    public var level: Int
    public var note: String?
    public var example: VocabularyExample?
}

public struct GrammarPattern: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var pattern: String
    public var meaning: String
    public var whenUsed: String
    public var example: VocabularyExample
    public var level: Int
}

/// A role-play character (spec §7). Personality and style are prompts for the AI, not caricatures.
public struct Persona: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var nameJa: String
    public var nameEn: String
    public var role: String
    public var roleJa: String
    public var personality: String
    /// Speech-rate multiplier relative to the learner's current comfortable rate.
    public var speakingRate: Double
    public var formality: Politeness
    public var style: String
}

public struct ScenarioBeat: Codable, Hashable, Sendable {
    /// What the partner says. Empty on the first beat of a role-reversal scenario (the learner starts).
    public var line: String
    public var kana: String
    public var english: String
    /// What the learner is expected to do, in English, used for hints.
    public var hintEn: String
    public var exampleResponses: [String]
    public var keyTerms: [KeyTermGroup]

    public init(line: String, kana: String, english: String, hintEn: String, exampleResponses: [String], keyTerms: [KeyTermGroup] = []) {
        self.line = line
        self.kana = kana
        self.english = english
        self.hintEn = hintEn
        self.exampleResponses = exampleResponses
        self.keyTerms = keyTerms
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        line = try c.decodeIfPresent(String.self, forKey: .line) ?? ""
        kana = try c.decodeIfPresent(String.self, forKey: .kana) ?? ""
        english = try c.decodeIfPresent(String.self, forKey: .english) ?? ""
        hintEn = try c.decode(String.self, forKey: .hintEn)
        exampleResponses = try c.decodeIfPresent([String].self, forKey: .exampleResponses) ?? []
        keyTerms = try c.decodeIfPresent([KeyTermGroup].self, forKey: .keyTerms) ?? []
    }
}

public struct Scenario: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var titleJa: String
    public var track: Track
    public var level: Int
    public var personaID: String
    /// One or two English sentences setting the scene, spoken before the role-play.
    public var situationEn: String
    /// The learner opens the conversation (spec §8).
    public var roleReversal: Bool
    public var targetTerms: [String]
    public var beats: [ScenarioBeat]
    public var closingLine: String
    public var closingKana: String
    public var closingEnglish: String
}

/// Keys for spoken coach instructions (spec §26). Text lives in cues.json.
public enum CueKey: String, CaseIterable, Codable, Sendable {
    case listen
    case yourTurn
    case answerInJapanese
    case sayInJapanese
    case tryAgain
    case good
    case veryNatural
    case moreDetail
    case meaningClear
    case moreNaturally
    case repeatAfterMe
    case slowly
    case naturalSpeed
    case listenAgain
    case noProblem
    case modelAnswer
    case question
    case startConversation
    case conversationEnd
    case nextOne
    case sessionStartWork
    case sessionStartEveryday
    case sessionStartGeneral
    case sessionEnd
    case onePhrase
    case wellDone
    case clearlyUnderstood
}

public struct CoachCue: Codable, Hashable, Sendable {
    public var ja: String
    public var kana: String
    public var en: String

    public init(ja: String, kana: String, en: String) {
        self.ja = ja
        self.kana = kana
        self.en = en
    }
}
