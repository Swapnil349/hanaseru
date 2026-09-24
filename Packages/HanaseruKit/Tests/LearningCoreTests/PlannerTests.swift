import Foundation
import Testing
@testable import LearningCore

@Suite("Session planning")
struct PlannerTests {
    let library = try! ContentLibrary.bundled()
    var planner: SessionPlanner { SessionPlanner(library: library) }
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test(arguments: [2, 5, 10, 20, 30])
    func planFitsTheTimeBudget(minutes: Int) {
        let plan = planner.plan(PlanningInput(minutes: minutes, focus: .surprise, now: now, seed: 42))
        #expect(!plan.exercises.isEmpty)
        #expect(Double(plan.estimatedSeconds) <= Double(minutes * 60) * 1.15 + 15)
        #expect(plan.closingItemID != nil)
    }

    @Test func fiveMinutesIncludesAConversation() {
        let plan = planner.plan(PlanningInput(minutes: 5, focus: .work, now: now, seed: 7))
        #expect(plan.exercises.contains { $0.kind == .conversation })
        #expect(plan.exercises.contains { $0.kind == .recall })
    }

    @Test func workFocusUsesWorkContent() {
        let plan = planner.plan(PlanningInput(minutes: 20, focus: .work, now: now, seed: 3))
        #expect(plan.track == .work)
        for exercise in plan.exercises {
            if let id = exercise.itemID { #expect(library.item(id: id)?.track == .work) }
            if case .conversation(let id, _) = exercise { #expect(library.scenario(id: id)?.track == .work) }
        }
    }

    @Test func planningIsDeterministicForASeed() {
        let a = planner.plan(PlanningInput(minutes: 10, focus: .surprise, now: now, seed: 99))
        let b = planner.plan(PlanningInput(minutes: 10, focus: .surprise, now: now, seed: 99))
        #expect(a == b)
    }

    @Test func itemsAreNotRepeatedWithinASession() {
        let plan = planner.plan(PlanningInput(minutes: 30, focus: .speaking, now: now, seed: 5))
        let ids = plan.exercises.compactMap(\.itemID)
        #expect(Set(ids).count == ids.count)
    }

    @Test func weakListeningIsRoutedToListeningPractice() {
        // An item the learner can say but can't catch by ear should get listening practice (spec §31).
        let scheduler = ReviewScheduler()
        var knowledge: [String: KnowledgeState] = [:]
        for item in library.items {
            var state = KnowledgeState(itemID: item.id, introducedAt: now)
            for dimension in SkillDimension.practisable {
                state = scheduler.record(state, dimension: dimension, grade: .easy, at: now.addingTimeInterval(-86_400 * 30))
            }
            knowledge[item.id] = state
        }
        var weak = knowledge["w.inspection.friday"]!
        weak = scheduler.record(weak, dimension: .listening, grade: .again, at: now.addingTimeInterval(-86_400))
        knowledge["w.inspection.friday"] = weak

        let plan = planner.plan(PlanningInput(minutes: 5, focus: .work, knowledge: knowledge,
                                              difficulty: DifficultyProfile(level: 5, englishSupport: 0.5, speechRate: 1, responseWindow: 8),
                                              now: now, seed: 11))
        #expect(plan.exercises.first == .listening(itemID: "w.inspection.friday"))
    }

    @Test func recurringMistakesArePrioritised() {
        let mistake = MistakeSummary(type: .pastTense, correction: "昨日、東京に行きました。", explanation: "", lastSaid: "昨日東京に行きます",
                                     itemID: "e.past.tokyo", occurrences: 4, lastSeen: now)
        let plan = planner.plan(PlanningInput(minutes: 5, focus: .speaking, recurringMistakes: [mistake], now: now, seed: 1))
        #expect(plan.exercises.contains(.recall(itemID: "e.past.tokyo")))
    }

    @Test func personalPhrasesArePrioritised() {
        let personal = LearningItem(id: "p.heard.1", japanese: "工程に遅れが出ています。", kana: "こうていにおくれがでています。",
                                    english: "The schedule is slipping.", track: .work, category: "heard", level: 2,
                                    promptEn: "Say: the schedule is slipping.", acceptableResponses: ["工程に遅れが出ています"],
                                    isPersonal: true)
        let merged = library.merging(personal: [personal])
        let plan = SessionPlanner(library: merged).plan(PlanningInput(minutes: 5, focus: .speaking, now: now, seed: 2))
        #expect(plan.exercises.contains { $0.itemID == personal.id })
    }
}
