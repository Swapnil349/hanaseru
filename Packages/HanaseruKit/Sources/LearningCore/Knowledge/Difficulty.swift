import Foundation

/// The internal difficulty model (spec §18, §34, §76). Level is never shown as a game level.
///
/// Difficulty rises through speed, less English, shorter response windows and longer, more natural
/// turns — not through obscure vocabulary.
public struct DifficultyProfile: Codable, Equatable, Sendable {
    /// 1 basic workplace phrases … 8 complex technical discussion.
    public var level: Int
    /// 1 = English instructions and glosses everywhere, 0 = Japanese only.
    public var englishSupport: Double
    /// Coach speech rate as a multiple of natural speed.
    public var speechRate: Double
    /// Seconds the coach waits for the learner to start speaking.
    public var responseWindow: TimeInterval

    public init(level: Int, englishSupport: Double, speechRate: Double, responseWindow: TimeInterval) {
        self.level = level
        self.englishSupport = englishSupport
        self.speechRate = speechRate
        self.responseWindow = responseWindow
    }

    /// Reasonable start for someone who lived in Japan but is rusty; the diagnostic (M2) will replace it.
    public static let starting = DifficultyProfile(level: 2, englishSupport: 0.8, speechRate: 0.85, responseWindow: 10)

    /// Decodes field by field so a partly written profile keeps what it has instead of resetting everything.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DifficultyProfile.starting
        level = try c.decodeIfPresent(Int.self, forKey: .level) ?? defaults.level
        englishSupport = try c.decodeIfPresent(Double.self, forKey: .englishSupport) ?? defaults.englishSupport
        speechRate = try c.decodeIfPresent(Double.self, forKey: .speechRate) ?? defaults.speechRate
        responseWindow = try c.decodeIfPresent(TimeInterval.self, forKey: .responseWindow) ?? defaults.responseWindow
    }

    private enum CodingKeys: String, CodingKey { case level, englishSupport, speechRate, responseWindow }

    public var usesEnglishGlosses: Bool { englishSupport >= 0.5 }
    public var usesEnglishPrompts: Bool { englishSupport >= 0.2 }

    /// Scales every think window: responseWindow / 10, clamped 0.7–1.4.
    public var windowScale: Double { min(1.4, max(0.7, responseWindow / 10)) }

    /// Language of the coach's own instructions. The English meaning of a line being taught is spoken in every mode.
    public var coachLanguage: CoachLanguage {
        if englishSupport >= 0.6 { return .english }
        if englishSupport >= 0.3 { return .bilingual }
        return .japanese
    }
}

public enum CoachLanguage: String, Codable, Sendable {
    /// Instructions in English.
    case english
    /// Japanese instruction, with its English gloss the first time it is used in a session.
    case bilingual
    /// Japanese instructions only.
    case japanese
}

public enum ExerciseKind: String, Codable, CaseIterable, Sendable {
    case listening
    case recall
    case conversation
    case shadowing
    case closing
}

public struct ExerciseResult: Codable, Equatable, Sendable {
    public var kind: ExerciseKind
    public var itemID: String?
    public var verdict: ResponseVerdict
    public var latency: TimeInterval?
    public var date: Date
    /// Scene line ("scenario#beat") or item id the turn practised.
    public var lineID: String?
    /// Scaffold level the turn was asked at (0–5).
    public var level: Int?
    /// What happened in the turn; preferred over `verdict` when present.
    public var outcome: TurnOutcome?

    public init(kind: ExerciseKind, itemID: String?, verdict: ResponseVerdict, latency: TimeInterval?, date: Date,
                lineID: String? = nil, level: Int? = nil, outcome: TurnOutcome? = nil) {
        self.kind = kind
        self.itemID = itemID
        self.verdict = verdict
        self.latency = latency
        self.date = date
        self.lineID = lineID
        self.level = level
        self.outcome = outcome
    }

    /// Counted as a success for difficulty adaptation: a clean answer (no help) when the outcome is known.
    public var isSuccess: Bool { outcome.map(\.isClean) ?? verdict.isSuccess }

    /// Unclear or skipped turns say nothing about ability.
    public var isScored: Bool { outcome?.isGraded ?? true }
}

/// Moves difficulty one step at a time based on recent outcomes.
public struct DifficultyAdapter: Sendable {
    public var minimumSamples: Int

    public init(minimumSamples: Int = 6) {
        self.minimumSamples = minimumSamples
    }

    public func adapted(_ profile: DifficultyProfile, recent results: [ExerciseResult]) -> DifficultyProfile {
        let scored = results.filter { $0.kind != .closing && $0.isScored }
        guard scored.count >= minimumSamples else { return profile }

        let successRate = Double(scored.filter(\.isSuccess).count) / Double(scored.count)
        let latencies = scored.compactMap(\.latency).sorted()
        let medianLatency = latencies.isEmpty ? 0 : latencies[latencies.count / 2]

        var next = profile
        if successRate >= 0.8 && medianLatency < 5 {
            next.level = min(8, profile.level + 1)
            next.englishSupport = max(0, profile.englishSupport - 0.1)
            next.speechRate = min(1.2, profile.speechRate + 0.05)
            next.responseWindow = max(5, profile.responseWindow - 1)
        } else if successRate <= 0.45 {
            next.level = max(1, profile.level - 1)
            next.englishSupport = min(1, profile.englishSupport + 0.15)
            next.speechRate = max(0.7, profile.speechRate - 0.05)
            next.responseWindow = min(14, profile.responseWindow + 2)
        } else if medianLatency > 7 {
            // Getting it right but slowly: give more time now; retrieval practice comes from scheduling.
            next.responseWindow = min(14, profile.responseWindow + 1)
        }
        return next
    }
}
