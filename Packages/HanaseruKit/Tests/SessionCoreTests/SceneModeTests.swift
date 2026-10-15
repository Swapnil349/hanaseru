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
        #expect(texts.contains("始めましょう。"))
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
        #expect(texts.contains("まず、せりふの練習です。"))
        #expect(!texts.contains { $0.hasPrefix("Step 1 of 3") })
        #expect(harness.runner.ledgerViolations.isEmpty)
    }

    @Test func watchingActsOutTheConversationWithoutAskingAnything() async throws {
        let library = try ContentLibrary.bundled()
        let scenario = try #require(library.scenario(id: "s.weekend.chat"))
        let lines = library.lines(in: scenario, learnerName: "")
        let harness = Harness(plan: scene, answers: [], library: library, options: SessionOptions(sceneMode: .watch))
        let summary = try #require(await harness.runToCompletion())
        #expect(harness.recognizer.listenCount == 0)
        #expect(summary.conversationTurns == 0)
        for line in lines {
            #expect(harness.synthesizer.count(line.partner?.japanese ?? "-") == 1)
            #expect(harness.synthesizer.count(line.japanese) == 1)
        }
        // The two characters take turns: the colleague, then you, line after line.
        let voices = harness.events.compactMap { event -> StageVoice? in
            if case .voice(let voice?) = event, voice != .narrator { return voice }
            return nil
        }
        #expect(voices == Array(repeating: [StageVoice.partner, .you], count: lines.count).flatMap { $0 } + [.partner])
        #expect(harness.events.contains { event in
            if case .stage(let info?) = event { return info.partnerName == "Nakamura-san" }
            return false
        })
    }

    @Test func theLearnerCanPlayTheColleague() async throws {
        let library = try ContentLibrary.bundled()
        let scenario = try #require(library.scenario(id: "s.weekend.chat"))
        let mine = library.lines(in: scenario, learnerName: "")
        let theirs = library.partnerSideLines(in: scenario, learnerName: "")
        // The colleague's three lines and the closing line; each after the learner's usual line but the first.
        #expect(theirs.map(\.japanese) == mine.compactMap { $0.partner?.japanese } + [scenario.closingLine])
        #expect(theirs.first?.partner == nil)
        #expect(Array(theirs.dropFirst()).compactMap { $0.partner?.japanese } == mine.map(\.japanese))

        let harness = Harness(plan: scene, answers: [], library: library,
                              options: SessionOptions(sceneMode: .conversationOnly, playAsPartner: true))
        let summary = try #require(await harness.runToCompletion())
        #expect(summary.conversationTurns == theirs.count)
        // The app says the learner's usual lines in the other voice; the colleague's are modelled for the learner.
        for line in mine {
            #expect(harness.synthesizer.spoken.contains { $0.text == line.japanese && $0.voice == .partner(nil) })
        }
        #expect(summary.results.allSatisfy { $0.lineID?.hasSuffix("~them") == true })
        #expect(harness.events.contains { event in
            if case .stage(let info?) = event { return info.learnerPlaysPartner }
            return false
        })
        let script = try #require(harness.runner.script().first)
        #expect(script.entries.filter(\.isLearner).map(\.japanese) == theirs.map(\.japanese))
    }

    @Test func scenesListTheirVocabulary() throws {
        let library = try ContentLibrary.bundled()
        let scenario = try #require(library.scenario(id: "s.site.pier"))
        let words = library.vocabulary(in: scenario).map(\.id)
        for id in scenario.targetTerms { #expect(words.contains(id)) }
        #expect(Set(words).count == words.count)
    }
}
