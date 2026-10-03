import Foundation

/// How much support a line gets (teach before test; support fades as the learner improves).
///
/// - S0 model: hear the English and the Japanese, then echo it. Nothing is asked.
/// - S1 guided: English plus the first chunk is given; finish the sentence.
/// - S2 cued: English only; say the whole line.
/// - S3 intent: only the goal ("Tell him whether…"); choose your own words.
/// - S4 free: the partner's Japanese only, answered in real time.
/// - S5 fluent: open, natural-speed variants.
public enum ScaffoldLevel: Int, Codable, Comparable, CaseIterable, Sendable {
    case model = 0
    case guided = 1
    case cued = 2
    case intent = 3
    case free = 4
    case fluent = 5

    public static func < (lhs: ScaffoldLevel, rhs: ScaffoldLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var easier: ScaffoldLevel { ScaffoldLevel(rawValue: max(0, rawValue - 1)) ?? .model }
    public var harder: ScaffoldLevel { ScaffoldLevel(rawValue: min(5, rawValue + 1)) ?? .fluent }

    public var title: String {
        switch self {
        case .model: "Model"
        case .guided: "Guided"
        case .cued: "Cued"
        case .intent: "Intent"
        case .free: "Free"
        case .fluent: "Fluent"
        }
    }

    /// Where a line starts when it has history from before scaffold levels were stored (spec §4.2).
    /// Returns nil when the line has never been practised: it must be introduced (taught) first.
    public static func entry(from knowledge: KnowledgeState?) -> ScaffoldLevel? {
        guard let knowledge else { return nil }
        let recall = knowledge.state(.spokenRecall)
        guard recall.reviews > 0 else { return nil }
        if recall.strength < 0.3 { return .guided }
        if recall.strength < 0.6 { return .cued }
        return .intent
    }
}

/// What happened in one production turn. There is no "wrong" that leads to asking again:
/// anything that isn't clean is followed by the model, one echo, and moving on.
public enum TurnOutcome: String, Codable, CaseIterable, Sendable {
    /// Natural answer, started quickly, with no help.
    case cleanFast
    /// Correct answer with no help.
    case clean
    /// Correct after a nudge, a hint, the English, or a peek.
    case hinted
    /// Meaning partly there ("Close — X was right").
    case partial
    /// Clear meaning, wrong politeness for the situation.
    case register
    /// The model had to be given (wrong, silent, or asked for the answer).
    case modelNeeded
    /// Speech wasn't recognisable as Japanese; not graded.
    case unclear
    /// Skipped by the learner; not graded.
    case skipped

    public var isClean: Bool { self == .clean || self == .cleanFast }
    public var isGraded: Bool { self != .unclear && self != .skipped }
    /// The learner got the meaning across (possibly imperfectly).
    public var communicated: Bool { isClean || self == .hinted || self == .partial || self == .register }

    /// Closest legacy verdict, for history and charts written before outcomes existed.
    public var legacyVerdict: ResponseVerdict {
        switch self {
        case .cleanFast: .natural
        case .clean: .acceptable
        case .hinted, .partial: .understandable
        case .register: .contextuallyInappropriate
        case .modelNeeded: .incorrect
        case .unclear: .unclear
        case .skipped: .noResponse
        }
    }

    /// Lower is worse; used to pick the "one to keep" line.
    public var severity: Int {
        switch self {
        case .modelNeeded: 0
        case .partial, .register: 1
        case .hinted: 2
        case .unclear, .skipped: 3
        case .clean: 4
        case .cleanFast: 5
        }
    }
}

/// Timing for one turn at one level (spec §2, LevelTiming).
public struct TurnTiming: Equatable, Sendable {
    /// Total think time before the answer is given.
    public var window: TimeInterval
    /// When the nudge (one more step of help) plays if nothing has been said.
    public var nudgeAt: TimeInterval
    /// Listening time after the nudge.
    public var afterNudge: TimeInterval
    /// Silence that ends the learner's turn.
    public var endSilence: TimeInterval
    /// Partner speech rate for this level (before persona and profile adjustments).
    public var partnerRate: Double

    public init(window: TimeInterval, nudgeAt: TimeInterval, afterNudge: TimeInterval, endSilence: TimeInterval, partnerRate: Double) {
        self.window = window
        self.nudgeAt = nudgeAt
        self.afterNudge = afterNudge
        self.endSilence = endSilence
        self.partnerRate = partnerRate
    }

    static func base(_ level: ScaffoldLevel) -> (window: TimeInterval, endSilence: TimeInterval, partnerRate: Double) {
        switch level {
        case .model: (window: 5.0, endSilence: 1.0, partnerRate: 0.85)
        case .guided: (window: 8.0, endSilence: 1.8, partnerRate: 0.85)
        case .cued: (window: 7.0, endSilence: 1.8, partnerRate: 0.90)
        case .intent: (window: 6.0, endSilence: 1.5, partnerRate: 0.95)
        case .free: (window: 5.0, endSilence: 1.4, partnerRate: 1.00)
        case .fluent: (window: 3.5, endSilence: 1.2, partnerRate: 1.05)
        }
    }

    /// W = base × windowScale × pace + 0.4 s per chunk beyond 3, clamped 2.5–14 s; nudge at W/2;
    /// after the nudge max(3, W − nudge + 1.5) s.
    public static func make(level: ScaffoldLevel, chunkCount: Int, profile: DifficultyProfile, paceFactor: Double = 1) -> TurnTiming {
        let base = base(level)
        let extra = 0.4 * Double(max(0, chunkCount - 3))
        let window = min(14, max(2.5, base.window * profile.windowScale * paceFactor + extra))
        let nudgeAt = 0.5 * window
        return TurnTiming(window: window, nudgeAt: nudgeAt, afterNudge: max(3.0, window - nudgeAt + 1.5),
                          endSilence: base.endSilence, partnerRate: base.partnerRate)
    }

    /// Partner rate = (table + profile speech rate − 0.85) × persona rate, clamped 0.7–1.15.
    public static func partnerRate(level: ScaffoldLevel, profile: DifficultyProfile, personaRate: Double) -> Double {
        let value = (base(level).partnerRate + profile.speechRate - 0.85) * personaRate
        return min(1.15, max(0.7, value))
    }

    /// An answer that is natural and starts faster than this counts as "clean, fast".
    public static func fastGate(_ level: ScaffoldLevel) -> TimeInterval {
        switch level {
        case .model, .guided, .cued: 2.5
        case .intent: 2.0
        case .free, .fluent: 2.0
        }
    }
}

public extension ReviewGrade {
    /// Spaced-repetition grade for a turn (spec §4.5). Nil when the turn shouldn't be graded.
    init?(outcome: TurnOutcome, level: ScaffoldLevel, onset: TimeInterval?) {
        switch outcome {
        case .cleanFast:
            self = .easy
        case .clean:
            if level == .guided || (onset ?? 0) > 6 { self = .hard } else { self = .good }
        case .hinted, .partial, .register:
            self = .hard
        case .modelNeeded:
            self = .again
        case .unclear, .skipped:
            return nil
        }
    }
}
