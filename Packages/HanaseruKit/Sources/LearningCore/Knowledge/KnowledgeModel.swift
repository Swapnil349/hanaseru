import Foundation

/// Independent dimensions of knowing an item (spec §32). Recognising 進捗 on paper says little about
/// catching it at speed or producing it in a meeting, so each dimension is scheduled on its own.
public enum SkillDimension: String, Codable, CaseIterable, Sendable, CodingKeyRepresentable {
    case recognition
    case listening
    case spokenRecall
    /// Intelligibility only — whether speech recognition understood the learner. Not pitch accent.
    case pronunciation
    case grammar
    case context

    /// Dimensions a session can deliberately practise.
    public static let practisable: [SkillDimension] = [.listening, .spokenRecall, .context]
}

public struct DimensionState: Codable, Equatable, Sendable {
    /// Rolling estimate of success, 0...1.
    public var strength: Double
    /// Days until the memory is expected to need refreshing.
    public var stabilityDays: Double
    public var due: Date
    public var reviews: Int
    public var lapses: Int
    public var lastReviewed: Date?

    public init(strength: Double = 0, stabilityDays: Double = 0, due: Date, reviews: Int = 0, lapses: Int = 0, lastReviewed: Date? = nil) {
        self.strength = strength
        self.stabilityDays = stabilityDays
        self.due = due
        self.reviews = reviews
        self.lapses = lapses
        self.lastReviewed = lastReviewed
    }

    public static func new(at date: Date) -> DimensionState { DimensionState(due: date) }
}

public struct KnowledgeState: Codable, Equatable, Identifiable, Sendable {
    public var id: String { itemID }
    public let itemID: String
    public var dimensions: [SkillDimension: DimensionState]
    /// Exponential moving average of seconds between "your turn" and the learner starting to speak (spec §79).
    public var averageLatency: Double?
    public var introducedAt: Date

    public init(itemID: String, introducedAt: Date) {
        self.itemID = itemID
        self.dimensions = [:]
        self.averageLatency = nil
        self.introducedAt = introducedAt
    }

    public func state(_ dimension: SkillDimension) -> DimensionState {
        dimensions[dimension] ?? .new(at: introducedAt)
    }

    public func isDue(_ dimension: SkillDimension, at date: Date) -> Bool {
        state(dimension).due <= date
    }

    public var isNew: Bool { dimensions.values.allSatisfy { $0.reviews == 0 } }

    /// The practisable dimension that most needs work: lowest strength, ties broken by earliest due date.
    public var weakestDimension: SkillDimension {
        SkillDimension.practisable.min { a, b in
            let sa = state(a), sb = state(b)
            if sa.strength != sb.strength { return sa.strength < sb.strength }
            return sa.due < sb.due
        } ?? .spokenRecall
    }

    /// Mean strength over dimensions that have actually been practised.
    public var mastery: Double {
        let practised = dimensions.values.filter { $0.reviews > 0 }
        guard !practised.isEmpty else { return 0 }
        return practised.map(\.strength).reduce(0, +) / Double(practised.count)
    }
}

public enum ReviewGrade: Int, Codable, Sendable, Comparable {
    case again = 0
    case hard
    case good
    case easy

    public static func < (lhs: ReviewGrade, rhs: ReviewGrade) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Converts an evaluation into a scheduling grade. A correct but slow answer is graded `hard`
    /// so the item comes back sooner for retrieval practice (spec §79: slow → fast → automatic).
    public init(verdict: ResponseVerdict, latency: TimeInterval?, slowThreshold: TimeInterval = 6, fastThreshold: TimeInterval = 2.5) {
        var grade: ReviewGrade
        switch verdict {
        case .natural: grade = .good
        case .acceptable: grade = .good
        case .understandable, .contextuallyInappropriate: grade = .hard
        case .incorrect, .unclear, .noResponse: grade = .again
        }
        if let latency {
            if grade >= .good && latency > slowThreshold { grade = .hard }
            if verdict == .natural && latency <= fastThreshold { grade = .easy }
        }
        self = grade
    }
}

/// A small spaced-repetition scheduler applied per dimension (spec §31).
public struct ReviewScheduler: Sendable {
    /// Lower bound on the interval, so a lapse comes back later in the day rather than instantly.
    public var minimumStabilityDays: Double
    public var maximumStabilityDays: Double

    public init(minimumStabilityDays: Double = 0.02, maximumStabilityDays: Double = 180) {
        self.minimumStabilityDays = minimumStabilityDays
        self.maximumStabilityDays = maximumStabilityDays
    }

    public func review(_ state: DimensionState, grade: ReviewGrade, at date: Date) -> DimensionState {
        var next = state
        let target: Double = [0.0, 0.55, 0.85, 1.0][grade.rawValue]
        next.strength = state.reviews == 0 ? target : state.strength * 0.6 + target * 0.4
        next.reviews += 1
        next.lastReviewed = date

        let base = max(state.stabilityDays, minimumStabilityDays)
        switch grade {
        case .again:
            next.lapses += 1
            next.stabilityDays = max(minimumStabilityDays, base * 0.3)
        case .hard:
            next.stabilityDays = max(0.25, base * 1.2)
        case .good:
            next.stabilityDays = max(1, base * (2 + next.strength))
        case .easy:
            next.stabilityDays = max(2, base * (3 + next.strength))
        }
        next.stabilityDays = min(next.stabilityDays, maximumStabilityDays)
        next.due = date.addingTimeInterval(next.stabilityDays * 86_400)
        return next
    }

    /// Records one practice outcome on a dimension and updates response latency.
    public func record(_ knowledge: KnowledgeState, dimension: SkillDimension, grade: ReviewGrade,
                       latency: TimeInterval? = nil, at date: Date) -> KnowledgeState {
        var updated = knowledge
        updated.dimensions[dimension] = review(knowledge.state(dimension), grade: grade, at: date)
        if let latency {
            updated.averageLatency = knowledge.averageLatency.map { $0 * 0.7 + latency * 0.3 } ?? latency
        }
        return updated
    }
}
