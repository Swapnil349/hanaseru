import Foundation
import Testing
import LearningCore
import ConversationCore
@testable import SessionCore

@Suite("Moving through a session: pause, ⏮ ↺ ⏭, hearing lines again, the script")
@MainActor
struct NavigationTests {
    let plan = SessionPlan(minutes: 10, focus: .conversation, track: .everyday,
                           exercises: [.conversation(scenarioID: "s.weekend.chat", turns: 10)], closingItemID: nil)

    /// The weekend chat, already practised, played as just the conversation; every answer is silence.
    func scene() async throws -> (harness: Harness, lines: [PracticeLine], scenario: Scenario) {
        let library = try ContentLibrary.bundled()
        let scenario = try #require(library.scenario(id: "s.weekend.chat"))
        let repository = InMemoryLearnerRepository()
        let day = Date().addingTimeInterval(-86_400)
        for line in library.lines(in: scenario, learnerName: "") {
            await repository.save(ReviewScheduler().record(KnowledgeState(itemID: line.id, introducedAt: day),
                                                           dimension: .spokenRecall, grade: .good, at: day))
        }
        let harness = Harness(plan: plan, answers: [], library: library, repository: repository,
                              options: SessionOptions(sceneMode: .conversationOnly))
        harness.recognizer.delay = 20_000_000
        return (harness, library.lines(in: scenario, learnerName: ""), scenario)
    }

    func partner(_ line: PracticeLine) -> String { line.partner?.japanese ?? "-" }

    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<2_000 where !condition() { try await Task.sleep(nanoseconds: 1_000_000) }
    }

    func finish(_ harness: Harness) async throws -> SessionSummary {
        for _ in 0..<2_500 where harness.summary == nil { try await Task.sleep(nanoseconds: 2_000_000) }
        return try #require(harness.summary)
    }

    @Test func pauseCarriesOnFromTheSameLine() async throws {
        let (harness, lines, _) = try await scene()
        harness.runner.start()
        try await waitUntil { harness.synthesizer.count(partner(lines[1])) > 0 }
        harness.runner.pause()
        #expect(harness.runner.isPaused)
        harness.runner.resume()
        let summary = try await finish(harness)
        // Not from the beginning: the first line and the scene's opening are heard once.
        #expect(harness.synthesizer.count(partner(lines[0])) == 1)
        #expect(harness.synthesizer.count("始めましょう。") == 1)
        // The paused line plays again from its start.
        #expect(harness.synthesizer.count(partner(lines[1])) == 2)
        #expect(summary.conversationTurns == lines.count)
    }

    @Test func nextMovesOnOneLine() async throws {
        let (harness, lines, scenario) = try await scene()
        harness.runner.start()
        try await waitUntil { harness.recognizer.listenCount > 0 }
        harness.runner.move(.next)
        let summary = try await finish(harness)
        // Only the line in progress is skipped, not the whole scene.
        for line in lines { #expect(harness.synthesizer.count(partner(line)) == 1) }
        #expect(harness.synthesizer.count(scenario.closingLine) == 1)
        #expect(summary.conversationTurns == lines.count - 1)
    }

    @Test func previousGoesBackOneLine() async throws {
        let (harness, lines, _) = try await scene()
        harness.runner.start()
        try await waitUntil { harness.synthesizer.count(partner(lines[1])) > 0 }
        harness.runner.move(.previous)
        let summary = try await finish(harness)
        #expect(harness.synthesizer.count(partner(lines[0])) == 2)
        #expect(harness.synthesizer.count(partner(lines[1])) == 2)
        #expect(harness.synthesizer.count(partner(lines[2])) == 1)
        #expect(summary.conversationTurns == lines.count + 1)
    }

    @Test func againReplaysTheLineWithoutCountingIt() async throws {
        let (harness, lines, _) = try await scene()
        harness.runner.start()
        try await waitUntil { harness.synthesizer.count(partner(lines[1])) > 0 }
        harness.runner.move(.again)
        let summary = try await finish(harness)
        #expect(harness.synthesizer.count(partner(lines[0])) == 1)
        #expect(harness.synthesizer.count(partner(lines[1])) == 2)
        #expect(summary.conversationTurns == lines.count)
        #expect(summary.results.filter { $0.lineID == lines[1].id }.count == 1)
    }

    @Test func aLineFromTheScriptStartsThere() async throws {
        let (harness, lines, _) = try await scene()
        harness.runner.start()
        try await waitUntil { harness.recognizer.listenCount > 0 }
        harness.runner.move(.to(part: 0, line: 2))
        _ = try await finish(harness)
        #expect(harness.synthesizer.count(partner(lines[1])) == 0)
        #expect(harness.synthesizer.count(partner(lines[2])) == 1)
    }

    @Test func hearingALineAgainPausesThenCarriesOn() async throws {
        let (harness, lines, _) = try await scene()
        harness.runner.start()
        try await waitUntil { harness.recognizer.listenCount > 0 }
        harness.runner.listen(to: [SpeechRequest(text: "もう一回聞きます。", language: .japanese)])
        try await waitUntil { harness.synthesizer.count("もう一回聞きます。") > 0 }
        #expect(harness.runner.isPaused)
        #expect(harness.synthesizer.count("もう一回聞きます。") == 1)
        harness.runner.resume()
        let summary = try await finish(harness)
        #expect(harness.synthesizer.count(partner(lines[0])) == 2)
        #expect(summary.conversationTurns == lines.count)
    }

    @Test func theScrubberGoesStraightToAnAnswer() async throws {
        let (harness, lines, _) = try await scene()
        harness.runner.start()
        try await waitUntil { harness.recognizer.listenCount > 0 }
        let places = harness.events.compactMap { event -> SessionTimeline? in
            if case .timeline(let place?) = event { return place }
            return nil
        }
        let timeline = try #require(places.last)
        // A stop at the start, at each line's question and answer, and at the end.
        #expect(timeline.stops.count == 2 + 2 * lines.count)
        // The learner's turn on the first line is its answer stop.
        #expect(timeline.stops[timeline.position].isAnswer)
        #expect(timeline.stops[timeline.position].line == 1)
        // The second line's answer: its question is skipped, the answer is heard, nothing is graded.
        harness.runner.move(.seek(4))
        let summary = try await finish(harness)
        #expect(harness.synthesizer.count(partner(lines[1])) == 0)
        #expect(harness.synthesizer.count(lines[1].japanese) >= 1)
        #expect(summary.conversationTurns == lines.count - 2)
        #expect(!summary.results.contains { $0.lineID == lines[1].id })
    }

    func timelines(_ harness: Harness) -> [SessionTimeline] {
        harness.events.compactMap { event -> SessionTimeline? in
            if case .timeline(let place?) = event { return place }
            return nil
        }
    }

    @Test func theScrubberCoversTheWholeSession() async throws {
        let library = try ContentLibrary.bundled()
        let scenario = try #require(library.scenario(id: "s.weekend.chat"))
        let lines = library.lines(in: scenario, learnerName: "")
        let mixed = SessionPlan(minutes: 10, focus: .surprise, track: .everyday,
                                exercises: [.recall(itemID: "e.past.tokyo"), .shadowing(itemID: "w.confirm.will"),
                                            .conversation(scenarioID: "s.weekend.chat", turns: 10)],
                                closingItemID: nil)
        let harness = Harness(plan: mixed, answers: [], library: library, options: SessionOptions(sceneMode: .conversationOnly))
        harness.recognizer.delay = 20_000_000
        harness.runner.start()
        try await waitUntil { harness.recognizer.listenCount > 0 }
        let timeline = try #require(timelines(harness).last)
        // A question and an answer for the phrase, one stop for "say it with me", then every stop of the scene.
        #expect(timeline.stops.count == 2 + 1 + (2 + 2 * lines.count))
        #expect(timeline.stops.first?.part == 1)
        // From the first phrase straight to the scene's second line.
        let target = try #require(timeline.stops.firstIndex { $0.part == 3 && $0.line == 2 && !$0.isAnswer })
        harness.runner.move(.seek(target))
        let summary = try await finish(harness)
        #expect(harness.synthesizer.count(partner(lines[0])) == 0)
        #expect(harness.synthesizer.count(partner(lines[1])) == 1)
        #expect(summary.conversationTurns == lines.count - 1)
    }

    @Test func aSceneContinuesWhereItStopped() async throws {
        let library = try ContentLibrary.bundled()
        let scenario = try #require(library.scenario(id: "s.weekend.chat"))
        let lines = library.lines(in: scenario, learnerName: "")
        let stopped = SessionTimeline.Stop(step: "Conversation", line: 3, isAnswer: false, japanese: "")
        let harness = Harness(plan: plan, answers: [], library: library,
                              options: SessionOptions(sceneMode: .conversationOnly, resumeAt: stopped, untimed: true))
        _ = try #require(await harness.runToCompletion())
        #expect(harness.synthesizer.count(partner(lines[0])) == 0)
        #expect(harness.synthesizer.count(partner(lines[1])) == 0)
        #expect(harness.synthesizer.count(partner(lines[2])) == 1)
    }

    @Test func theScriptCanBeWrittenOutInThreeWays() throws {
        let library = try ContentLibrary.bundled()
        let scenario = try #require(library.scenario(id: "s.weekend.chat"))
        let lines = library.lines(in: scenario, learnerName: "")
        let text = ScriptPart.text(of: [library.script(of: scenario, learnerName: "")])
        for line in lines {
            #expect(text.contains(line.japanese))
            #expect(text.contains(line.romaji))
            #expect(text.contains(line.english))
            if let partner = line.partner {
                #expect(text.contains(partner.japanese))
                #expect(text.contains(partner.romaji))
            }
        }
    }

    @Test func aStuckVoiceNeverStopsTheSession() async throws {
        let library = try ContentLibrary.bundled()
        let scenario = try #require(library.scenario(id: "s.weekend.chat"))
        let lines = library.lines(in: scenario, learnerName: "")
        let synthesizer = StuckSynthesizer(stuckOn: lines[0].partner?.japanese ?? "-")
        let recognizer = ScriptedRecognizer([])
        let runner = SessionRunner(plan: plan, library: library,
                                   voice: .init(synthesizer: synthesizer, recognizer: recognizer, feedback: RecordingFeedback()),
                                   ai: OfflineAIProvider(library: library), repository: InMemoryLearnerRepository(),
                                   options: SessionOptions(sceneMode: .conversationOnly))
        runner.start()
        try await waitUntil { synthesizer.isStuck }
        #expect(synthesizer.isStuck)
        // The voice ignores the move; the session goes on to the next line anyway.
        runner.move(.next)
        for _ in 0..<5_000 where !synthesizer.texts.contains(lines[1].partner?.japanese ?? "-") {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(synthesizer.texts.contains(lines[1].partner?.japanese ?? "-"))
        synthesizer.release()
        runner.stop()
    }

    // MARK: - The answer on screen

    func focus(at level: ScaffoldLevel, _ harness: Harness) -> FocusInfo? {
        harness.events.compactMap { event -> FocusInfo? in
            if case .focus(let info) = event, info.level == level { return info }
            return nil
        }.first
    }

    @Test func theAnswerIsOnScreenWhileTheLineIsLearned() async throws {
        let harness = Harness(plan: Fixture.plan, answers: ["いいえ、特に問題はありません"], library: Fixture.library(),
                              repository: await Fixture.repository(level: .cued))
        _ = try #require(await harness.runToCompletion())
        let info = try #require(focus(at: .cued, harness))
        #expect(info.answerShown)
        #expect(info.visibleJapanese == Fixture.model)
        #expect(info.promptAudio.first?.text == Fixture.partner)
        #expect(info.answerAudio.first?.text == Fixture.model)
        // Reading it while learning the line isn't counted as help.
        #expect(harness.summary?.results.first?.outcome == .cleanFast)
    }

    @Test func theAnswerCanWaitUntilAfterTheTurn() async throws {
        let harness = Harness(plan: Fixture.plan, answers: ["いいえ、特に問題はありません"], library: Fixture.library(),
                              repository: await Fixture.repository(level: .cued),
                              options: SessionOptions(answerDisplay: .afterTurn))
        _ = try #require(await harness.runToCompletion())
        let info = try #require(focus(at: .cued, harness))
        #expect(!info.answerShown)
        #expect(info.visibleJapanese.isEmpty)
    }

    // MARK: - The script

    @Test func theScriptHasEveryLineOfTheScene() throws {
        let library = try ContentLibrary.bundled()
        let scenario = try #require(library.scenario(id: "s.weekend.chat"))
        let lines = library.lines(in: scenario, learnerName: "")
        let harness = Harness(plan: plan, answers: [], library: library)
        let part = try #require(harness.runner.script().first)
        let mine = part.entries.filter(\.isLearner)
        let theirs: [String] = part.entries.filter { !$0.isLearner }.map(\.japanese)
        let partnerLines: [String] = lines.compactMap { $0.partner?.japanese } + [scenario.closingLine]
        #expect(mine.map(\.japanese) == lines.map(\.japanese))
        #expect(mine.compactMap(\.startLine) == Array(lines.indices))
        #expect(theirs == partnerLines)
        #expect(part.entries.allSatisfy { !$0.audio.isEmpty })
    }

    @Test func theScriptCoversEveryPartOfASession() throws {
        let mixed = SessionPlan(minutes: 5, focus: .surprise, track: .everyday,
                                exercises: [.recall(itemID: "e.past.tokyo"), .listening(itemID: "e.restaurant.colleagues"),
                                            .conversation(scenarioID: "s.weekend.chat", turns: 2)],
                                closingItemID: nil)
        let harness = Harness(plan: mixed, answers: [])
        let script = harness.runner.script()
        #expect(script.map(\.index) == [0, 1, 2])
        #expect(script[0].entries.contains { $0.isLearner && $0.lineID == "e.past.tokyo" })
        #expect(script[1].entries.contains { $0.isLearner })
        // Only the lines this session practises can be started from.
        #expect(script[2].entries.compactMap(\.startLine) == [0, 1])
    }
}

/// Hangs on one line, ignoring cancellation and stopSpeaking, until released.
@MainActor
final class StuckSynthesizer: SpeechSynthesisProvider {
    let stuckOn: String
    private(set) var texts: [String] = []
    private var held: CheckedContinuation<Void, Never>?
    var isStuck: Bool { held != nil }

    init(stuckOn: String) {
        self.stuckOn = stuckOn
    }

    func speak(_ request: SpeechRequest) async {
        texts.append(request.text)
        guard request.text == stuckOn, held == nil else { return }
        await withCheckedContinuation { held = $0 }
    }

    func stopSpeaking() {}

    func release() {
        held?.resume()
        held = nil
    }
}
