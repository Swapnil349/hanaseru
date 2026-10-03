import Foundation

/// The colleague who speaks right before a practice line.
public struct PracticePartner: Hashable, Sendable {
    public var japanese: String
    public var kana: String
    public var english: String
    public var nameJa: String
    public var nameEn: String
    public var gender: VoiceGender?
    /// Persona speaking-rate multiplier.
    public var speakingRate: Double

    public init(japanese: String, kana: String, english: String, nameJa: String, nameEn: String,
                gender: VoiceGender?, speakingRate: Double) {
        self.japanese = japanese
        self.kana = kana
        self.english = english
        self.nameJa = nameJa
        self.nameEn = nameEn
        self.gender = gender
        self.speakingRate = speakingRate
    }
}

/// One line the learner practises saying — from a phrase item or from a scene — in a single shape,
/// with everything needed to teach it before asking for it.
public struct PracticeLine: Hashable, Sendable, Identifiable {
    /// Item id, or "scenarioID#beatID" for a scene line. Also the knowledge key.
    public var id: String
    public var japanese: String
    public var kana: String
    public var english: String
    public var chunks: [Chunk]
    public var noteEn: String?
    /// Difficulty 1–8.
    public var level: Int
    /// "Say: …" / "Ask: …" in English (S1–S2).
    public var cueEn: String
    /// The goal without the words (S3).
    public var intentEn: String
    /// Scene-setting sentence when there's no partner line.
    public var situationEn: String?
    public var partner: PracticePartner?
    /// Every acceptable way to say it (the model first).
    public var references: [String]
    public var keyTerms: [KeyTermGroup]
    public var mistakes: [MistakePattern]
    public var politeness: Politeness
    /// The partner's easier either/or re-ask, used as the nudge once English cues are gone.
    public var choiceVariant: ModelLine?
    /// Set when the line is a phrase item.
    public var itemID: String?

    public init(id: String, japanese: String, kana: String, english: String, chunks: [Chunk], noteEn: String? = nil,
                level: Int, cueEn: String, intentEn: String, situationEn: String? = nil, partner: PracticePartner? = nil,
                references: [String], keyTerms: [KeyTermGroup], mistakes: [MistakePattern], politeness: Politeness,
                choiceVariant: ModelLine? = nil, itemID: String? = nil) {
        self.id = id
        self.japanese = japanese
        self.kana = kana
        self.english = english
        self.chunks = chunks
        self.noteEn = noteEn
        self.level = level
        self.cueEn = cueEn
        self.intentEn = intentEn
        self.situationEn = situationEn
        self.partner = partner
        self.references = references
        self.keyTerms = keyTerms
        self.mistakes = mistakes
        self.politeness = politeness
        self.choiceVariant = choiceVariant
        self.itemID = itemID
    }

    /// Questions are cued with "Ask:", everything else with "Say:".
    public var isQuestion: Bool { PracticeLine.isQuestion(japanese) }

    public var evaluationTarget: EvaluationTarget {
        EvaluationTarget(references: references, keyTerms: keyTerms, commonMistakes: mistakes,
                         modelAnswer: japanese, chunks: chunks)
    }

    /// Words likely to be said, to bias speech recognition.
    public var contextualStrings: [String] {
        var words = [japanese] + chunks.map(\.ja) + keyTerms.flatMap(\.anyOf)
        words.append(contentsOf: references)
        var seen = Set<String>()
        return words.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func isQuestion(_ japanese: String) -> Bool {
        let trimmed = japanese.trimmingCharacters(in: .whitespaces)
        return trimmed.hasSuffix("か。") || trimmed.hasSuffix("か？") || trimmed.hasSuffix("？") || trimmed.hasSuffix("?")
    }

    static func defaultCue(english: String, japanese: String) -> String {
        (isQuestion(japanese) ? "Ask: " : "Say: ") + english
    }

    /// Chunks from content, or split after punctuation when the content has none.
    static func chunks(_ authored: [Chunk]?, japanese: String, kana: String) -> [Chunk] {
        if let authored, !authored.isEmpty { return authored }
        let jaParts = JapaneseText.punctuationChunks(japanese)
        let kanaParts = JapaneseText.punctuationChunks(kana)
        if !jaParts.isEmpty && jaParts.count == kanaParts.count {
            return zip(jaParts, kanaParts).map { Chunk(ja: $0, kana: $1) }
        }
        return [Chunk(ja: japanese, kana: kana.isEmpty ? japanese : kana)]
    }
}

public extension ContentLibrary {
    /// A phrase item as a practice line.
    func practiceLine(item: LearningItem) -> PracticeLine {
        let partner = item.partner.map { line -> PracticePartner in
            let persona = line.personaID.flatMap { self.persona(id: $0) }
            return PracticePartner(japanese: line.japanese, kana: line.kana, english: line.english,
                                   nameJa: persona?.nameJa ?? "", nameEn: persona?.nameEn ?? "",
                                   gender: persona?.voiceGender, speakingRate: persona?.speakingRate ?? 1)
        }
        let cue = item.cueEn ?? item.promptEn ?? PracticeLine.defaultCue(english: item.english, japanese: item.japanese)
        return PracticeLine(
            id: item.id, japanese: item.japanese, kana: item.kana, english: item.english,
            chunks: PracticeLine.chunks(item.chunks, japanese: item.japanese, kana: item.kana),
            noteEn: item.noteEn, level: item.level, cueEn: cue, intentEn: item.intentEn ?? cue,
            situationEn: item.situationEn, partner: partner, references: item.referenceResponses,
            keyTerms: item.keyTerms, mistakes: item.commonMistakes + CommonMistakes.general,
            politeness: item.politeness, itemID: item.id
        )
    }

    /// The learner's line in one beat of a scene (the first, most typical answer is the one taught).
    func practiceLine(scenario: Scenario, beatIndex: Int, learnerName: String) -> PracticeLine? {
        guard scenario.beats.indices.contains(beatIndex) else { return nil }
        let beat = scenario.beats[beatIndex]
        guard let first = beat.responses.first?.personalized(name: learnerName) else { return nil }
        let persona = persona(id: scenario.personaID)
        let partner: PracticePartner? = beat.line.isEmpty ? nil : PracticePartner(
            japanese: beat.line, kana: beat.kana, english: beat.english,
            nameJa: persona?.nameJa ?? "", nameEn: persona?.nameEn ?? "",
            gender: persona?.voiceGender, speakingRate: persona?.speakingRate ?? 1
        )
        // Model first, then the other answers, then their kana (a kana transcript must match too).
        let filled = beat.responses.map { $0.personalized(name: learnerName) }
        var references: [String] = []
        for text in filled.map(\.japanese) + filled.map(\.kana) where !text.isEmpty && !references.contains(text) {
            references.append(text)
        }
        let cue = beat.cueEn ?? PracticeLine.defaultCue(english: first.english, japanese: first.japanese)
        return PracticeLine(
            id: "\(scenario.id)#\(scenario.beatID(at: beatIndex))",
            japanese: first.japanese, kana: first.kana, english: first.english,
            chunks: PracticeLine.chunks(first.chunks, japanese: first.japanese, kana: first.kana),
            noteEn: first.noteEn, level: first.level ?? scenario.level, cueEn: cue,
            intentEn: beat.intentEn ?? beat.hintEn, situationEn: nil, partner: partner,
            references: references, keyTerms: beat.keyTerms, mistakes: CommonMistakes.general,
            politeness: persona?.formality ?? .professional, choiceVariant: beat.lineVariants?.choice
        )
    }

    /// Every learner line of a scene, in order.
    func lines(in scenario: Scenario, learnerName: String) -> [PracticeLine] {
        scenario.beats.indices.compactMap { practiceLine(scenario: scenario, beatIndex: $0, learnerName: learnerName) }
    }

    /// Fills a cue template's placeholders ({english}, {name}, {title}, {topic}, …).
    func fill(_ template: String, _ values: [String: String]) -> String {
        var text = template
        for (key, value) in values {
            text = text.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return text
    }
}
