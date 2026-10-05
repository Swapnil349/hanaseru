import Foundation
import Testing
import LearningCore
import ConversationCore
@testable import SessionCore

@Suite("Scenes: start anywhere, skip the explanations once practised")
@MainActor
struct SceneModeTests {
    let scene = SessionPlan(minutes: 10, focus: .conversation, track: .everyday,
                            exercises: [.conversation(scenarioID: "s.weekend.chat", turns: 10)], closingItemID: nil)

    /// A repository where every line of the scene has been practised once.
    func practised(_ library: ContentLibrary) async -> InMemoryLearnerRepository {
        let repository = InMemoryLearnerRepository()
        let day = Date().addingTimeInterval(-86_400)
        let scenario = library.scenario(id: "s.weekend.chat")!
        for line in library.lines(in: scenario, learnerName: "Swapnil") {
            await repository.save(ReviewScheduler().record(KnowledgeState(itemID: line.id, introducedAt: day),
                                                           dimension: .spokenRecall, grade: .good, at: day))
        }
        return repository
    }

    @Test func aPractisedSceneGoesStraightToTheConversation() async throws {
        let library = try ContentLibrary.bundled()
        let harness = Harness(plan: scene, answers: [], library: library, repository: await practised(library))
        _ = try #require(await harness.runToCompletion())
        let texts = harness.synthesizer.texts
        #expect(!texts.contains("Three steps: listen, practise your lines, then the real conversation."))
        #expect(!texts.contains { $0.hasPrefix("Step 1 of 3") })
        #expect(texts.contains("Nakamura-san starts."))
        #expect(harness.runner.ledgerViolations.isEmpty)
    }

    @Test func theConversationCanStartAtAnyLine() async throws {
        let library = try ContentLibrary.bundled()
        let scenario = try #require(library.scenario(id: "s.weekend.chat"))
        let lines = library.lines(in: scenario, learnerName: "Swapnil")
        let harness = Harness(plan: scene, answers: [], library: library, repository: await practised(library),
                              options: SessionOptions(sceneMode: .conversationOnly, sceneStartBeat: 1))
        _ = try #require(await harness.runToCompletion())
        #expect(harness.synthesizer.count(lines[0].partner?.japanese ?? "-") == 0)
        #expect(harness.synthesizer.count(lines[1].partner?.japanese ?? "-") == 1)
        #expect(harness.summary?.conversationTurns == lines.count - 1)
    }

    @Test func practiseLinesSkipsTheBriefButPractisesEachLine() async throws {
        let library = try ContentLibrary.bundled()
        let harness = Harness(plan: scene, answers: [], library: library,
                              options: SessionOptions(sceneMode: .practiseLines))
        _ = try #require(await harness.runToCompletion())
        let texts = harness.synthesizer.texts
        #expect(texts.contains("Your lines first. Repeat each one after me."))
        #expect(!texts.contains { $0.hasPrefix("Step 1 of 3") })
        #expect(harness.runner.ledgerViolations.isEmpty)
    }

    @Test func scenesListTheirVocabulary() throws {
        let library = try ContentLibrary.bundled()
        let scenario = try #require(library.scenario(id: "s.site.pier"))
        let words = library.vocabulary(in: scenario).map(\.id)
        for id in scenario.targetTerms { #expect(words.contains(id)) }
        #expect(Set(words).count == words.count)
    }
}
