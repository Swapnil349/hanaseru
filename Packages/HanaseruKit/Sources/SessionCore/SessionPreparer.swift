import Foundation
import LearningCore

/// Builds a plan from the learner's stored state: knowledge, recurring mistakes, personal phrases,
/// recently used scenarios and current difficulty.
@MainActor
public struct SessionPreparer {
    public let library: ContentLibrary
    public let repository: LearnerRepository

    public init(library: ContentLibrary, repository: LearnerRepository) {
        self.library = library
        self.repository = repository
    }

    /// Returns the plan and the library it was planned against (bundled content + personal phrases).
    public func prepare(minutes: Int, focus: SessionFocus, seed: UInt64? = nil, now: Date = Date()) async -> (plan: SessionPlan, library: ContentLibrary) {
        let personal = await repository.personalItems()
        let merged = library.merging(personal: personal)
        let learner = await repository.snapshot()
        let knowledge = await repository.allKnowledge()
        let mistakes = await repository.recurringMistakes(limit: 10)
        let recentScenarios = await repository.recentScenarioIDs(limit: 4)

        let input = PlanningInput(
            minutes: minutes, focus: focus, knowledge: knowledge, recurringMistakes: mistakes,
            recentScenarioIDs: recentScenarios, difficulty: learner.difficulty, now: now,
            seed: seed ?? UInt64.random(in: 1...UInt64.max)
        )
        return (SessionPlanner(library: merged).plan(input), merged)
    }
}
