import Foundation
import Testing
import LearningCore
import ConversationCore
@testable import SessionCore

@Suite("My scenes in a session: a speech has no one else to wait for")
@MainActor
struct MySceneSessionTests {
    static let speech = MyScene(
        id: "my.speech", kind: .monologue, description: "Introduce myself at the morning meeting",
        createdAt: 1_760_000_000_000, updatedAt: 1_760_000_000_000,
        result: SceneResult(
            title: "Introducing myself", titleJa: "自己紹介", situationEn: "The morning meeting.",
            beats: [
                SceneResult.Beat(learner: SceneResult.Line(japanese: "おはようございます。", kana: "おはようございます。",
                                                           english: "Good morning."),
                                 hintEn: "Greet everyone"),
                SceneResult.Beat(learner: SceneResult.Line(japanese: "{name}です。", kana: "{name}です。",
                                                           english: "I'm {name}."),
                                 hintEn: "Say your name"),
                SceneResult.Beat(learner: SceneResult.Line(japanese: "インドから来ました。", kana: "いんどからきました。",
                                                           english: "I'm from India."),
                                 hintEn: "Say where you're from"),
            ]
        )
    )

    let plan = SessionPlan(minutes: 10, focus: .conversation, track: .everyday,
                           exercises: [.conversation(scenarioID: "my.speech", turns: 10)], closingItemID: nil)

    func library() throws -> ContentLibrary {
        try ContentLibrary.bundled().including([Self.speech], learnerName: "Swapnil")
    }

    func partnerLines(_ harness: Harness) -> [ScriptLine] {
        harness.events.compactMap { event -> ScriptLine? in
            if case .line(let line) = event, case .partner = line.role { return line }
            return nil
        }
    }

    @Test(arguments: [SceneMode.fullLesson, .practiseLines, .conversationOnly, .watch])
    func aSpeechPlaysThroughWithoutAnEmptyPartnerLine(mode: SceneMode) async throws {
        let library = try library()
        let harness = Harness(plan: plan, answers: ["おはようございます", "Swapnilです", "インドから来ました"],
                              library: library, options: SessionOptions(sceneMode: mode))
        let summary = try #require(await harness.runToCompletion())
        #expect(summary.scenarioIDs == ["my.speech"])
        // No one else speaks: no partner line, no empty bubble, no partner voice.
        #expect(partnerLines(harness).isEmpty)
        #expect(!harness.synthesizer.spoken.contains { request in
            if case .partner = request.voice { return true }
            return false
        })
        #expect(!harness.synthesizer.texts.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
        // Every sentence is modelled.
        for sentence in ["おはようございます。", "Swapnilです。", "インドから来ました。"] {
            #expect(harness.synthesizer.texts.contains(sentence), "\(mode): \(sentence)")
        }
    }

    @Test func eachSentenceIsCuedOutLoudBeforeTheLearnerSaysIt() async throws {
        let library = try library()
        let harness = Harness(plan: plan, answers: ["おはようございます", "Swapnilです", "インドから来ました"],
                              library: library, options: SessionOptions(sceneMode: .conversationOnly))
        let summary = try #require(await harness.runToCompletion())
        #expect(summary.conversationTurns == 3)
        // With the phone in a pocket a chime alone wouldn't say which sentence is next: the English cue does.
        #expect(inOrder(harness.synthesizer.texts, ["Greet everyone", "Say your name", "Say where you're from"]))
        #expect(harness.recognizer.listenCount >= 3)
    }

    @Test func playingTheOtherPartOfASpeechPlaysTheSpeech() async throws {
        let library = try library()
        let harness = Harness(plan: plan, answers: [], library: library,
                              options: SessionOptions(sceneMode: .conversationOnly, playAsPartner: true))
        let summary = try #require(await harness.runToCompletion())
        #expect(summary.conversationTurns == 3)
        let script = harness.runner.script()
        #expect(script.first?.entries.filter(\.isLearner).count == 3)
    }
}
