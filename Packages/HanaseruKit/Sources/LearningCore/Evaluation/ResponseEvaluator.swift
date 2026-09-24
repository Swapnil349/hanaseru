import Foundation

/// Fuzzy verdict categories (spec §40). A response is never "wrong" merely for differing from an example.
public enum ResponseVerdict: String, Codable, CaseIterable, Sendable {
    /// Natural, the way a Japanese colleague would say it.
    case natural
    /// Correct and fine; a more natural version may exist.
    case acceptable
    /// Meaning gets through, but the phrasing is off.
    case understandable
    /// Grammatical but wrong for the situation (e.g. too casual for a senior engineer).
    case contextuallyInappropriate
    case incorrect
    /// Speech was heard but not recognisable as an answer.
    case unclear
    case noResponse

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ResponseVerdict(rawValue: raw) ?? .understandable
    }

    /// Counted as a success for scheduling and difficulty.
    public var isSuccess: Bool { self == .natural || self == .acceptable }
    /// The learner got their meaning across, even if imperfectly (communication first, spec §75).
    public var communicated: Bool { isSuccess || self == .understandable || self == .contextuallyInappropriate }
}

/// What a response is compared against.
public struct EvaluationTarget: Sendable {
    public var references: [String]
    public var keyTerms: [KeyTermGroup]
    public var commonMistakes: [MistakePattern]
    public var modelAnswer: String

    public init(references: [String], keyTerms: [KeyTermGroup], commonMistakes: [MistakePattern] = [], modelAnswer: String) {
        self.references = references
        self.keyTerms = keyTerms
        self.commonMistakes = commonMistakes
        self.modelAnswer = modelAnswer
    }

    public init(item: LearningItem) {
        self.init(
            references: item.referenceResponses,
            keyTerms: item.keyTerms,
            commonMistakes: item.commonMistakes + CommonMistakes.general,
            modelAnswer: item.japanese
        )
    }

    public init(listening check: ListeningCheck) {
        self.init(references: [check.modelAnswer], keyTerms: check.answerTerms, modelAnswer: check.modelAnswer)
    }

    public init(beat: ScenarioBeat) {
        self.init(
            references: beat.exampleResponses,
            keyTerms: beat.keyTerms,
            commonMistakes: CommonMistakes.general,
            modelAnswer: beat.exampleResponses.first ?? ""
        )
    }
}

public struct LocalEvaluation: Equatable, Sendable {
    public var verdict: ResponseVerdict
    public var similarity: Double
    public var missingTerms: [KeyTermGroup]
    public var matchedMistakes: [MistakePattern]
    public var modelAnswer: String
    /// False when the heuristic can't really judge (e.g. a valid answer phrased differently from every example).
    /// The session asks the AI for a second opinion in that case.
    public var isConfident: Bool
}

/// Offline, deterministic evaluator. Deliberately lenient: it rewards meaning (key terms) over exact wording.
public struct ResponseEvaluator: Sendable {
    public var naturalThreshold: Double
    public var acceptableThreshold: Double

    public init(naturalThreshold: Double = 0.88, acceptableThreshold: Double = 0.55) {
        self.naturalThreshold = naturalThreshold
        self.acceptableThreshold = acceptableThreshold
    }

    public func evaluate(_ transcript: String, against target: EvaluationTarget) -> LocalEvaluation {
        let normalized = JapaneseText.normalize(transcript)
        let best = JapaneseText.bestSimilarity(transcript, to: target.references)
        let missing = target.keyTerms.filter { !JapaneseText.contains(transcript, anyOf: $0.anyOf) }
        func result(_ verdict: ResponseVerdict, confident: Bool, mistakes: [MistakePattern] = []) -> LocalEvaluation {
            LocalEvaluation(verdict: verdict, similarity: best, missingTerms: missing, matchedMistakes: mistakes,
                            modelAnswer: target.modelAnswer, isConfident: confident)
        }

        guard !normalized.isEmpty else { return result(.noResponse, confident: true) }
        guard JapaneseText.containsJapanese(transcript) else { return result(.unclear, confident: true) }

        let mistakes = target.commonMistakes.filter { $0.matches(transcript) }
        if let first = mistakes.first {
            // Politeness slips are about context, not grammar (spec §12).
            let verdict: ResponseVerdict = first.type == .politeness ? .contextuallyInappropriate : .incorrect
            return result(verdict, confident: true, mistakes: mistakes)
        }

        if best >= naturalThreshold { return result(.natural, confident: true) }

        if target.keyTerms.isEmpty {
            if best >= acceptableThreshold { return result(.acceptable, confident: best >= 0.7) }
            if best >= 0.3 { return result(.understandable, confident: false) }
            return result(.incorrect, confident: false)
        }

        if missing.isEmpty {
            // All the meaning-carrying words are there: at least acceptable.
            return result(.acceptable, confident: best >= acceptableThreshold)
        }
        let coverage = 1 - Double(missing.count) / Double(target.keyTerms.count)
        if coverage >= 0.5 || best >= acceptableThreshold { return result(.understandable, confident: false) }
        return result(.incorrect, confident: false)
    }
}

/// Error patterns that apply to any response, independent of the item (spec §30).
public enum CommonMistakes {
    public static let general: [MistakePattern] = [
        MistakePattern(
            id: "general.past-time-non-past-verb",
            type: .pastTense,
            whenContainsAll: [
                KeyTermGroup(["昨日", "きのう", "先週", "せんしゅう", "先月", "せんげつ", "去年", "きょねん", "おととい"]),
                KeyTermGroup(["ます"]),
            ],
            // 「先週から働いています」 is correct (continuing state), so から / ています don't trigger it.
            unlessContainsAny: ["ました", "でした", "かった", "から", "ています", "ている"],
            correction: "〜ました",
            explanation: "With a past time word like 昨日 or 先週, use the past form: 〜ます becomes 〜ました."
        ),
        MistakePattern(
            id: "general.i-adjective-deshita",
            type: .conjugation,
            // Explicit endings only: な-adjectives like きれいでした are correct and must not match.
            whenContainsAll: [KeyTermGroup(["しいでした", "かいでした", "きいでした", "さいでした", "たいでした", "ついでした",
                                            "むいでした", "いいでした", "よいでした", "くいでした", "ないでした"])],
            correction: "〜かったです",
            explanation: "い-adjectives make their past with かった: 忙しい becomes 忙しかったです, not 忙しいでした."
        ),
    ]
}
