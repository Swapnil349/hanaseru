import Foundation

/// What the learner asked for on the home screen (spec §43).
public enum SessionFocus: String, CaseIterable, Codable, Sendable {
    case surprise
    case work
    case everyday
    case conversation
    case listening
    case speaking
    case shadowing

    public var title: String {
        switch self {
        case .surprise: "Surprise me"
        case .work: "Work Japanese"
        case .everyday: "Everyday"
        case .conversation: "Conversation"
        case .listening: "Listening"
        case .speaking: "Speaking"
        case .shadowing: "Shadowing"
        }
    }
}

public enum PlannedExercise: Equatable, Sendable {
    case listening(itemID: String)
    case recall(itemID: String)
    case shadowing(itemID: String)
    case conversation(scenarioID: String, turns: Int)

    public var kind: ExerciseKind {
        switch self {
        case .listening: .listening
        case .recall: .recall
        case .shadowing: .shadowing
        case .conversation: .conversation
        }
    }

    public var itemID: String? {
        switch self {
        case .listening(let id), .recall(let id), .shadowing(let id): id
        case .conversation: nil
        }
    }

    /// Rough duration including cues, one retry and feedback.
    public var estimatedSeconds: Int {
        switch self {
        case .listening: 50
        case .recall: 45
        case .shadowing: 45
        case .conversation(_, let turns): 30 + turns * 30
        }
    }
}

public struct SessionPlan: Equatable, Sendable {
    public var minutes: Int
    public var focus: SessionFocus
    /// nil means a mix of work and everyday Japanese.
    public var track: Track?
    public var exercises: [PlannedExercise]
    /// The "one phrase to remember" said at the end (spec §89).
    public var closingItemID: String?

    public init(minutes: Int, focus: SessionFocus, track: Track?, exercises: [PlannedExercise], closingItemID: String?) {
        self.minutes = minutes
        self.focus = focus
        self.track = track
        self.exercises = exercises
        self.closingItemID = closingItemID
    }

    public var estimatedSeconds: Int {
        exercises.map(\.estimatedSeconds).reduce(SessionPlanner.overheadSeconds, +)
    }
}

public struct PlanningInput: Sendable {
    public var minutes: Int
    public var focus: SessionFocus
    public var knowledge: [String: KnowledgeState]
    public var recurringMistakes: [MistakeSummary]
    public var recentScenarioIDs: [String]
    public var difficulty: DifficultyProfile
    public var now: Date
    public var seed: UInt64

    public init(minutes: Int, focus: SessionFocus, knowledge: [String: KnowledgeState] = [:],
                recurringMistakes: [MistakeSummary] = [], recentScenarioIDs: [String] = [],
                difficulty: DifficultyProfile = .starting, now: Date = Date(), seed: UInt64 = UInt64.random(in: 1...UInt64.max)) {
        self.minutes = minutes
        self.focus = focus
        self.knowledge = knowledge
        self.recurringMistakes = recurringMistakes
        self.recentScenarioIDs = recentScenarioIDs
        self.difficulty = difficulty
        self.now = now
        self.seed = seed
    }
}

/// Answers "what Japanese would be most useful right now?" (spec §68) for a given time budget.
public struct SessionPlanner: Sendable {
    /// Intro plus closing phrase.
    public static let overheadSeconds = 45

    public let library: ContentLibrary

    public init(library: ContentLibrary) {
        self.library = library
    }

    public func plan(_ input: PlanningInput) -> SessionPlan {
        var rng = SeededGenerator(seed: input.seed)
        let track = chooseTrack(for: input.focus, using: &rng)
        let shape = Self.shape(for: input.focus)

        let candidates = candidateItems(track: track, difficulty: input.difficulty)
        var priorities: [String: Double] = [:]
        for item in candidates {
            priorities[item.id] = priority(of: item, input: input) + Double.random(in: 0...0.25, using: &rng)
        }

        var exercises: [PlannedExercise] = []
        var usedItems = Set<String>()
        var usedScenarios = Set<String>()
        var newItems = 0
        let maxNewItems = max(3, input.minutes / 2 + 1)
        var remaining = input.minutes * 60 - Self.overheadSeconds
        var step = 0

        while remaining > 20 && step < 60 {
            let kind = shape[step % shape.count]
            step += 1

            if kind == .conversation {
                guard remaining >= 90,
                      let scenario = chooseScenario(track: track, input: input, excluding: usedScenarios, using: &rng)
                else { continue }
                let affordable = (remaining - 30) / 30
                let turns = min(scenario.beats.count, affordable, input.minutes >= 10 ? 6 : 4)
                guard turns >= 2 else { continue }
                let exercise = PlannedExercise.conversation(scenarioID: scenario.id, turns: turns)
                exercises.append(exercise)
                usedScenarios.insert(scenario.id)
                remaining -= exercise.estimatedSeconds
                continue
            }

            let allowNew = newItems < maxNewItems
            guard let item = chooseItem(for: kind, from: candidates, priorities: priorities, input: input,
                                        excluding: usedItems, allowNew: allowNew) else { continue }
            let exercise: PlannedExercise
            switch kind {
            case .listening: exercise = .listening(itemID: item.id)
            case .shadowing: exercise = .shadowing(itemID: item.id)
            default: exercise = .recall(itemID: item.id)
            }
            if exercise.estimatedSeconds > remaining + 15 { continue }
            exercises.append(exercise)
            usedItems.insert(item.id)
            if input.knowledge[item.id]?.isNew ?? true { newItems += 1 }
            remaining -= exercise.estimatedSeconds
        }

        if exercises.isEmpty, let fallback = candidates.first(where: \.supportsRecall) ?? candidates.first {
            exercises = [fallback.supportsRecall ? .recall(itemID: fallback.id) : .shadowing(itemID: fallback.id)]
        }

        return SessionPlan(minutes: input.minutes, focus: input.focus, track: track, exercises: exercises,
                           closingItemID: closingItem(for: exercises, track: track))
    }

    // MARK: - Choices

    static func shape(for focus: SessionFocus) -> [ExerciseKind] {
        switch focus {
        case .surprise, .work, .everyday:
            [.listening, .recall, .conversation, .shadowing, .recall, .listening, .recall, .conversation, .shadowing]
        case .conversation:
            [.conversation, .recall, .conversation, .recall]
        case .listening:
            [.listening, .listening, .shadowing]
        case .speaking:
            [.recall, .recall, .shadowing]
        case .shadowing:
            [.shadowing, .shadowing, .recall]
        }
    }

    private func chooseTrack(for focus: SessionFocus, using rng: inout SeededGenerator) -> Track? {
        switch focus {
        case .work: return .work
        case .everyday: return .everyday
        case .surprise: return Double.random(in: 0..<1, using: &rng) < 0.6 ? .work : .everyday
        case .conversation, .listening, .speaking, .shadowing: return nil
        }
    }

    private func candidateItems(track: Track?, difficulty: DifficultyProfile) -> [LearningItem] {
        let fitting = library.items.filter { item in
            (track == nil || item.track == track || item.isPersonal) && item.level <= difficulty.level + 1
        }
        if !fitting.isEmpty { return fitting }
        // Nothing at this level for the track: fall back to the easiest items in it.
        let inTrack = library.items.filter { track == nil || $0.track == track }
        let easiest = inTrack.map(\.level).min() ?? 1
        return inTrack.filter { $0.level <= easiest + 1 }
    }

    private func priority(of item: LearningItem, input: PlanningInput) -> Double {
        var score: Double
        if let knowledge = input.knowledge[item.id], !knowledge.isNew {
            let due = SkillDimension.practisable.contains { knowledge.isDue($0, at: input.now) }
            score = (1 - knowledge.mastery) + (due ? 0.8 : 0)
        } else {
            score = 0.6
        }
        if item.isPersonal { score += 0.5 }

        let recurringTypes = Set(input.recurringMistakes.filter { $0.occurrences >= 2 }.map(\.type))
        let mistakeItems = Set(input.recurringMistakes.compactMap(\.itemID))
        // Practise recurring mistakes naturally (spec §30): the exact item first, then items with the same error type.
        if mistakeItems.contains(item.id) {
            score += 0.8
        } else if item.commonMistakes.contains(where: { recurringTypes.contains($0.type) }) {
            score += 0.4
        }
        if item.level == input.difficulty.level || item.level == input.difficulty.level + 1 { score += 0.2 }
        return score
    }

    private func chooseItem(for kind: ExerciseKind, from candidates: [LearningItem], priorities: [String: Double],
                            input: PlanningInput, excluding used: Set<String>, allowNew: Bool) -> LearningItem? {
        let dimension: SkillDimension = switch kind {
        case .listening: .listening
        case .shadowing: .context
        default: .spokenRecall
        }
        let eligible = candidates.filter { item in
            guard !used.contains(item.id) else { return false }
            switch kind {
            case .listening: guard item.supportsListening else { return false }
            case .recall: guard item.supportsRecall else { return false }
            default: break
            }
            let isNew = input.knowledge[item.id]?.isNew ?? true
            return allowNew || !isNew
        }
        return eligible.max { a, b in
            score(a, dimension: dimension, priorities: priorities, input: input)
                < score(b, dimension: dimension, priorities: priorities, input: input)
        }
    }

    private func score(_ item: LearningItem, dimension: SkillDimension, priorities: [String: Double], input: PlanningInput) -> Double {
        var value = priorities[item.id] ?? 0
        // Route each item to the exercise that trains its weakest skill (spec §31–32).
        if let knowledge = input.knowledge[item.id], !knowledge.isNew,
           knowledge.weakestDimension == dimension,
           knowledge.state(dimension).strength < knowledge.mastery - 0.1 {
            value += 0.4
        }
        return value
    }

    private func chooseScenario(track: Track?, input: PlanningInput, excluding used: Set<String>,
                                using rng: inout SeededGenerator) -> Scenario? {
        let inTrack = library.scenarios.filter { (track == nil || $0.track == track) && !used.contains($0.id) }
        guard !inTrack.isEmpty else { return nil }
        let atLevel = inTrack.filter { $0.level <= input.difficulty.level + 1 }
        let pool = atLevel.isEmpty ? inTrack.filter { $0.level == inTrack.map(\.level).min() } : atLevel
        let fresh = pool.filter { !input.recentScenarioIDs.contains($0.id) }
        let options = fresh.isEmpty ? pool : fresh
        return options.randomElement(using: &rng)
    }

    private func closingItem(for exercises: [PlannedExercise], track: Track?) -> String? {
        let itemIDs = exercises.compactMap(\.itemID)
        if let recall = exercises.first(where: { $0.kind == .recall })?.itemID { return recall }
        if let any = itemIDs.first { return any }
        return library.items.first { track == nil || $0.track == track }?.id
    }
}

/// Deterministic generator so plans are reproducible in tests (SplitMix64).
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
