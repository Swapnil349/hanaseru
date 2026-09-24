import Foundation
import LearningCore

/// What the session needs to know about the learner.
public struct LearnerSnapshot: Equatable, Sendable {
    public var name: String
    public var difficulty: DifficultyProfile

    public init(name: String, difficulty: DifficultyProfile) {
        self.name = name
        self.difficulty = difficulty
    }
}

/// Persistence boundary for the learning engine (spec §55 layer 1). The app implements it with SwiftData.
@MainActor
public protocol LearnerRepository: AnyObject {
    func snapshot() async -> LearnerSnapshot
    func knowledge(for itemIDs: [String]) async -> [String: KnowledgeState]
    func allKnowledge() async -> [String: KnowledgeState]
    func save(_ knowledge: KnowledgeState) async
    func record(_ mistake: MistakeObservation) async
    func recurringMistakes(limit: Int) async -> [MistakeSummary]
    func personalItems() async -> [LearningItem]
    func recentResults(limit: Int) async -> [ExerciseResult]
    func recentScenarioIDs(limit: Int) async -> [String]
    func saveDifficulty(_ difficulty: DifficultyProfile) async
    func record(_ summary: SessionSummary) async
}

/// In-memory implementation used by tests and SwiftUI previews.
@MainActor
public final class InMemoryLearnerRepository: LearnerRepository {
    public var learner: LearnerSnapshot
    public private(set) var knowledgeByID: [String: KnowledgeState] = [:]
    public private(set) var mistakes: [MistakeObservation] = []
    public private(set) var sessions: [SessionSummary] = []
    public var personal: [LearningItem] = []

    public init(learner: LearnerSnapshot = LearnerSnapshot(name: "Swapnil", difficulty: .starting)) {
        self.learner = learner
    }

    public func snapshot() async -> LearnerSnapshot { learner }

    public func knowledge(for itemIDs: [String]) async -> [String: KnowledgeState] {
        knowledgeByID.filter { itemIDs.contains($0.key) }
    }

    public func allKnowledge() async -> [String: KnowledgeState] { knowledgeByID }

    public func save(_ knowledge: KnowledgeState) async {
        knowledgeByID[knowledge.itemID] = knowledge
    }

    public func record(_ mistake: MistakeObservation) async {
        mistakes.append(mistake)
    }

    public func recurringMistakes(limit: Int) async -> [MistakeSummary] {
        let grouped = Dictionary(grouping: mistakes, by: \.aggregationKey)
        return grouped.values.compactMap { group -> MistakeSummary? in
            guard let last = group.max(by: { $0.date < $1.date }) else { return nil }
            return MistakeSummary(type: last.type, correction: last.correction, explanation: last.explanation,
                                  lastSaid: last.said, itemID: last.itemID, occurrences: group.count, lastSeen: last.date)
        }
        .sorted { $0.occurrences > $1.occurrences }
        .prefix(limit)
        .map { $0 }
    }

    public func personalItems() async -> [LearningItem] { personal }

    public func recentResults(limit: Int) async -> [ExerciseResult] {
        Array(sessions.flatMap(\.results).suffix(limit))
    }

    public func recentScenarioIDs(limit: Int) async -> [String] {
        Array(sessions.flatMap(\.scenarioIDs).suffix(limit))
    }

    public func saveDifficulty(_ difficulty: DifficultyProfile) async {
        learner.difficulty = difficulty
    }

    public func record(_ summary: SessionSummary) async {
        sessions.append(summary)
    }
}
