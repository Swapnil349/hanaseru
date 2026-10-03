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
    /// Short note the coach can speak (12 words or fewer, Japanese only inside 「」).
    public var spokenEn: String?

    public init(id: String, type: MistakeType, whenContainsAll: [KeyTermGroup], unlessContainsAny: [String] = [],
                correction: String, explanation: String, spokenEn: String? = nil) {
        self.id = id
        self.type = type
        self.whenContainsAll = whenContainsAll
        self.unlessContainsAny = unlessContainsAny
        self.correction = correction
        self.explanation = explanation
        self.spokenEn = spokenEn
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(MistakeType.self, forKey: .type)
        whenContainsAll = try c.decode([KeyTermGroup].self, forKey: .whenContainsAll)
        unlessContainsAny = try c.decodeIfPresent([String].self, forKey: .unlessContainsAny) ?? []
        correction = try c.decode(String.self, forKey: .correction)
        explanation = try c.decode(String.self, forKey: .explanation)
        spokenEn = try c.decodeIfPresent(String.self, forKey: .spokenEn)
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
    public var modelAnswerKana: String
    public var modelAnswerEn: String
    /// English preview of what the sentence is about, said before it plays (never gives the answer away).
    public var topicEn: String?
    /// Easier either/or question whose options are Japanese answer words.
    public var choiceQuestionJa: String?
    public var choiceQuestionKana: String?
    public var choiceQuestionEn: String?
    public var distractorTerms: [KeyTermGroup]?

    public init(questionJa: String, questionEn: String, answerTerms: [KeyTermGroup], modelAnswer: String,
                modelAnswerKana: String = "", modelAnswerEn: String = "", topicEn: String? = nil,
                choiceQuestionJa: String? = nil, choiceQuestionKana: String? = nil, choiceQuestionEn: String? = nil,
                distractorTerms: [KeyTermGroup]? = nil) {
        self.questionJa = questionJa
        self.questionEn = questionEn
        self.answerTerms = answerTerms
        self.modelAnswer = modelAnswer
        self.modelAnswerKana = modelAnswerKana
        self.modelAnswerEn = modelAnswerEn
        self.topicEn = topicEn
        self.choiceQuestionJa = choiceQuestionJa
        self.choiceQuestionKana = choiceQuestionKana
        self.choiceQuestionEn = choiceQuestionEn
        self.distractorTerms = distractorTerms
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        questionJa = try c.decode(String.self, forKey: .questionJa)
        questionEn = try c.decode(String.self, forKey: .questionEn)
        answerTerms = try c.decode([KeyTermGroup].self, forKey: .answerTerms)
        modelAnswer = try c.decode(String.self, forKey: .modelAnswer)
        modelAnswerKana = try c.decodeIfPresent(String.self, forKey: .modelAnswerKana) ?? ""
        modelAnswerEn = try c.decodeIfPresent(String.self, forKey: .modelAnswerEn) ?? ""
        topicEn = try c.decodeIfPresent(String.self, forKey: .topicEn)
        choiceQuestionJa = try c.decodeIfPresent(String.self, forKey: .choiceQuestionJa)
        choiceQuestionKana = try c.decodeIfPresent(String.self, forKey: .choiceQuestionKana)
        choiceQuestionEn = try c.decodeIfPresent(String.self, forKey: .choiceQuestionEn)
        distractorTerms = try c.decodeIfPresent([KeyTermGroup].self, forKey: .distractorTerms)
    }
}

/// A phrase-sized piece of a line (文節), used for hints, build-up and partial feedback.
public struct Chunk: Codable, Hashable, Sendable {
    public var ja: String
    public var kana: String

    public init(ja: String, kana: String? = nil) {
        self.ja = ja
        self.kana = kana ?? ja
    }

    public init(from decoder: Decoder) throws {
        // A bare string is a chunk whose reading is the same text.
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            ja = text
            kana = text
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let japanese = try c.decode(String.self, forKey: .ja)
        ja = japanese
        kana = try c.decodeIfPresent(String.self, forKey: .kana) ?? japanese
    }

    private enum CodingKeys: String, CodingKey { case ja, kana }
}

public enum VoiceGender: String, Codable, Sendable {
    case male
    case female
}

/// A line the learner can say, always taught with its reading and meaning before it is asked for
/// (teach before test: the learner is never asked to produce Japanese they haven't been given).
public struct ModelLine: Codable, Hashable, Sendable {
    public var japanese: String
    public var kana: String
    public var english: String
    public var chunks: [Chunk]?
    /// One short teaching note (12 words or fewer), spoken the first time the line is introduced.
    public var noteEn: String?
    /// Difficulty of this particular line when it differs from its scene (greetings are 1).
    public var level: Int?

    public init(japanese: String, kana: String = "", english: String = "", chunks: [Chunk]? = nil,
                noteEn: String? = nil, level: Int? = nil) {
        self.japanese = japanese
        self.kana = kana
        self.english = english
        self.chunks = chunks
        self.noteEn = noteEn
        self.level = level
    }

    public init(from decoder: Decoder) throws {
        // Accept a bare Japanese string for older content files.
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            japanese = text
            kana = ""
            english = ""
            chunks = nil
            noteEn = nil
            level = nil
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        japanese = try c.decode(String.self, forKey: .japanese)
        kana = try c.decodeIfPresent(String.self, forKey: .kana) ?? ""
        english = try c.decodeIfPresent(String.self, forKey: .english) ?? ""
        chunks = try c.decodeIfPresent([Chunk].self, forKey: .chunks)
        noteEn = try c.decodeIfPresent(String.self, forKey: .noteEn)
        level = try c.decodeIfPresent(Int.self, forKey: .level)
    }

    private enum CodingKeys: String, CodingKey { case japanese, kana, english, chunks, noteEn, level }

    /// Replaces the `{name}` placeholder used in self-introductions.
    public func personalized(name: String) -> ModelLine {
        let who = name.isEmpty ? "…" : name
        func fill(_ text: String) -> String { text.replacingOccurrences(of: "{name}", with: who) }
        return ModelLine(
            japanese: fill(japanese), kana: fill(kana), english: fill(english),
            chunks: chunks?.map { Chunk(ja: fill($0.ja), kana: fill($0.kana)) },
            noteEn: noteEn, level: level
        )
    }
}

/// The colleague's line that comes before an item, so practice happens in context.
public struct PartnerLine: Codable, Hashable, Sendable {
    public var japanese: String
    public var kana: String
    public var english: String
    public var personaID: String?

    public init(japanese: String, kana: String = "", english: String = "", personaID: String? = nil) {
        self.japanese = japanese
        self.kana = kana
        self.english = english
        self.personaID = personaID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        japanese = try c.decode(String.self, forKey: .japanese)
        kana = try c.decodeIfPresent(String.self, forKey: .kana) ?? ""
        english = try c.decodeIfPresent(String.self, forKey: .english) ?? ""
        personaID = try c.decodeIfPresent(String.self, forKey: .personaID)
    }

    private enum CodingKeys: String, CodingKey { case japanese, kana, english, personaID }
}

/// Easier and harder ways the partner can say a line: an either/or re-ask, and an open question.
public struct LineVariants: Codable, Hashable, Sendable {
    public var choice: ModelLine?
    public var open: ModelLine?

    public init(choice: ModelLine? = nil, open: ModelLine? = nil) {
        self.choice = choice
        self.open = open
    }
}

/// A can-do mission inside a scene (e.g. "Say whether there's a problem").
public struct SceneMission: Codable, Hashable, Sendable {
    public var text: String
    public var beatIDs: [String]

    public init(text: String, beatIDs: [String]) {
        self.text = text
        self.beatIDs = beatIDs
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
    public var chunks: [Chunk]?
    public var noteEn: String?
    /// One sentence setting the scene where this line is said.
    public var situationEn: String?
    /// "Say: ..." or "Ask: ..." with the English meaning, used while the line is guided.
    public var cueEn: String?
    /// The goal without the words, used once the learner knows the line.
    public var intentEn: String?
    /// What a colleague says right before this line, so it is practised in context.
    public var partner: PartnerLine?

    public init(
        id: String, japanese: String, kana: String, romaji: String = "", english: String,
        literal: String? = nil, track: Track, category: String, level: Int, kind: ItemKind = .phrase,
        politeness: Politeness = .professional, usageNote: String? = nil, grammar: [String] = [],
        terms: [String] = [], promptEn: String? = nil, acceptableResponses: [String] = [],
        keyTerms: [KeyTermGroup] = [], commonMistakes: [MistakePattern] = [],
        listening: ListeningCheck? = nil, naturalAlternatives: [String] = [], isPersonal: Bool = false,
        chunks: [Chunk]? = nil, noteEn: String? = nil, situationEn: String? = nil, cueEn: String? = nil,
        intentEn: String? = nil, partner: PartnerLine? = nil
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
        self.chunks = chunks
        self.noteEn = noteEn
        self.situationEn = situationEn
        self.cueEn = cueEn
        self.intentEn = intentEn
        self.partner = partner
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
        chunks = try c.decodeIfPresent([Chunk].self, forKey: .chunks)
        noteEn = try c.decodeIfPresent(String.self, forKey: .noteEn)
        situationEn = try c.decodeIfPresent(String.self, forKey: .situationEn)
        cueEn = try c.decodeIfPresent(String.self, forKey: .cueEn)
        intentEn = try c.decodeIfPresent(String.self, forKey: .intentEn)
        partner = try c.decodeIfPresent(PartnerLine.self, forKey: .partner)
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
    /// Used to pick a distinct Japanese voice for the partner.
    public var voiceGender: VoiceGender?
}

public struct ScenarioBeat: Codable, Hashable, Sendable {
    /// Stable id within the scenario (e.g. "problem"); `Scenario.beatID(at:)` supplies a fallback.
    public var id: String?
    /// What the partner says. Empty on the first beat of a role-reversal scenario (the learner starts).
    public var line: String
    public var kana: String
    public var english: String
    /// What the learner is expected to do, in English, used for hints.
    public var hintEn: String
    /// Model answers the learner is taught before being asked (the "screenplay" line), most typical first.
    public var responses: [ModelLine]
    public var keyTerms: [KeyTermGroup]
    /// What to convey once the words are known (S3), e.g. "Tell him whether there's any problem."
    public var intentEn: String?
    /// Overrides the default "Say: {english}" cue.
    public var cueEn: String?
    public var lineChunks: [Chunk]?
    public var lineVariants: LineVariants?

    public init(id: String? = nil, line: String, kana: String, english: String, hintEn: String, responses: [ModelLine],
                keyTerms: [KeyTermGroup] = [], intentEn: String? = nil, cueEn: String? = nil,
                lineChunks: [Chunk]? = nil, lineVariants: LineVariants? = nil) {
        self.id = id
        self.line = line
        self.kana = kana
        self.english = english
        self.hintEn = hintEn
        self.responses = responses
        self.keyTerms = keyTerms
        self.intentEn = intentEn
        self.cueEn = cueEn
        self.lineChunks = lineChunks
        self.lineVariants = lineVariants
    }

    public init(line: String, kana: String, english: String, hintEn: String, exampleResponses: [String], keyTerms: [KeyTermGroup] = []) {
        self.init(line: line, kana: kana, english: english, hintEn: hintEn,
                  responses: exampleResponses.map { ModelLine(japanese: $0) }, keyTerms: keyTerms)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        line = try c.decodeIfPresent(String.self, forKey: .line) ?? ""
        kana = try c.decodeIfPresent(String.self, forKey: .kana) ?? ""
        english = try c.decodeIfPresent(String.self, forKey: .english) ?? ""
        hintEn = try c.decode(String.self, forKey: .hintEn)
        if let lines = try c.decodeIfPresent([ModelLine].self, forKey: .responses) {
            responses = lines
        } else {
            responses = try c.decodeIfPresent([ModelLine].self, forKey: .exampleResponses) ?? []
        }
        keyTerms = try c.decodeIfPresent([KeyTermGroup].self, forKey: .keyTerms) ?? []
        intentEn = try c.decodeIfPresent(String.self, forKey: .intentEn)
        cueEn = try c.decodeIfPresent(String.self, forKey: .cueEn)
        lineChunks = try c.decodeIfPresent([Chunk].self, forKey: .lineChunks)
        lineVariants = try c.decodeIfPresent(LineVariants.self, forKey: .lineVariants)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(line, forKey: .line)
        try c.encode(kana, forKey: .kana)
        try c.encode(english, forKey: .english)
        try c.encode(hintEn, forKey: .hintEn)
        try c.encode(responses, forKey: .responses)
        try c.encode(keyTerms, forKey: .keyTerms)
        try c.encodeIfPresent(intentEn, forKey: .intentEn)
        try c.encodeIfPresent(cueEn, forKey: .cueEn)
        try c.encodeIfPresent(lineChunks, forKey: .lineChunks)
        try c.encodeIfPresent(lineVariants, forKey: .lineVariants)
    }

    private enum CodingKeys: String, CodingKey {
        case id, line, kana, english, hintEn, responses, exampleResponses, keyTerms, intentEn, cueEn, lineChunks, lineVariants
    }

    /// Japanese text of the model answers (used by the evaluator as references).
    public var exampleResponses: [String] { responses.map(\.japanese) }
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
    /// Short place phrase, e.g. "at the pier" ("Back at the pier. Sato-san says:").
    public var placeEn: String?
    /// The scene's can-do goal.
    public var canDoEn: String?
    public var missionsEn: [SceneMission]?

    /// The beat's stable id ("problem"), or "b<n>" when the content has none.
    public func beatID(at index: Int) -> String {
        guard beats.indices.contains(index), let id = beats[index].id else { return "b" + String(index + 1) }
        return id
    }
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
    // Teach-first coaching (scaffolded turns, screenplay, help commands).
    case say
    case ask
    case youSay
    case youLine
    case youStart
    case itStarts
    case like
    case hereIsHow
    case noProblemHere
    case hereItIs
    case didntCatch
    case echoLater
    case youCouldSay
    case close
    case wasRight
    case naturalVersion
    case morePolite
    case alsoNatural
    case micCheck
    case takeYourTime
    case sayWithMe
    case sceneIntro
    case listenFirst
    case performStart
    case performYouStart
    case listenFor
    case itWas
    case thatsRight
    case helpIntro
    case chimeMeansTurn
    case ifMissed
    case toHearSlowly
    case stuckHelp
    case alwaysAnswer
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
