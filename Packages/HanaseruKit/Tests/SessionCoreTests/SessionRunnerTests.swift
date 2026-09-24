import Foundation
import Testing
import LearningCore
import ConversationCore
@testable import SessionCore

// MARK: - Fakes

@MainActor
final class FakeSynthesizer: SpeechSynthesisProvider {
    private(set) var spoken: [SpeechRequest] = []
    func speak(_ request: SpeechRequest) async { spoken.append(request) }
    func stopSpeaking() {}
    var japanese: [String] { spoken.filter { $0.language == .japanese }.map(\.text) }
}

/// Answers each listening turn from a script; silence once the script runs out.
@MainActor
final class ScriptedRecognizer: SpeechRecognitionProvider {
    var script: [String]
    /// Simulated thinking time, so tests can act mid-session.
    var delay: UInt64 = 0
    private(set) var listenCount = 0
    let processingDescription = "test"

    init(_ script: [String]) {
        self.script = script
    }

    func listen(_ options: ListenOptions, onPartial: @escaping @MainActor (String) -> Void) async -> ListenResult {
        listenCount += 1
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        guard !script.isEmpty else { return .silence }
        let text = script.removeFirst()
        onPartial(text)
        return ListenResult(transcript: text, confidence: 0.9, latency: 1.5, speakingDuration: 2, outcome: text.isEmpty ? .noSpeech : .speech)
    }

    func cancelListening() {}
}

@MainActor
final class RecordingFeedback: CueFeedbackProvider {
    private(set) var cues: [HapticCue] = []
    func play(_ cue: HapticCue) { cues.append(cue) }
}

@MainActor
struct Harness {
    let library = try! ContentLibrary.bundled()
    let synthesizer = FakeSynthesizer()
    let recognizer: ScriptedRecognizer
    let feedback = RecordingFeedback()
    let repository = InMemoryLearnerRepository()
    let runner: SessionRunner
    var events: [SessionEvent] { eventLog.events }
    private let eventLog = EventLog()

    init(plan: SessionPlan, answers: [String]) {
        recognizer = ScriptedRecognizer(answers)
        runner = SessionRunner(
            plan: plan, library: library,
            voice: .init(synthesizer: synthesizer, recognizer: recognizer, feedback: feedback),
            ai: OfflineAIProvider(library: library), repository: repository
        )
        let log = eventLog
        runner.onEvent = { log.events.append($0) }
    }

    /// Starts the session and waits (up to ~5 s) for it to finish.
    func runToCompletion() async -> SessionSummary? {
        runner.start()
        for _ in 0..<2_500 {
            if let summary = summary { return summary }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return summary
    }

    var summary: SessionSummary? {
        for event in events { if case .finished(let summary) = event { return summary } }
        return nil
    }
}

@MainActor
final class EventLog {
    var events: [SessionEvent] = []
}

// MARK: - Tests

@Suite("Hands-free session runner")
@MainActor
struct SessionRunnerTests {
    let plan = SessionPlan(
        minutes: 5, focus: .surprise, track: .everyday,
        exercises: [
            .recall(itemID: "e.past.tokyo"),
            .listening(itemID: "e.restaurant.colleagues"),
            .shadowing(itemID: "w.confirm.will"),
            .conversation(scenarioID: "s.weekend.chat", turns: 3),
        ],
        closingItemID: "w.confirm.will"
    )

    let answers = [
        "昨日、東京に行きます。",          // recall: past-tense mistake
        "昨日、東京に行きました。",        // recall: retry after the model answer
        "会社の人と行きました。",          // listening: correct
        "確認しておきます。",              // shadowing, slow
        "確認しておきます。",              // shadowing, natural speed
        "友達と出かけました。",            // conversation turn 1
        "はい、楽しかったです。",          // conversation turn 2
        "まだ決めていません。",            // conversation turn 3
        "確認しておきます。",              // closing phrase
    ]

    @Test func completesAFullHandsFreeSession() async throws {
        let harness = Harness(plan: plan, answers: answers)
        let summary = try #require(await harness.runToCompletion())

        #expect(summary.completedNormally)
        #expect(summary.conversationTurns == 3)
        #expect(summary.phraseJapanese == "確認しておきます。")
        #expect(summary.results.count >= 4)
        #expect(harness.recognizer.listenCount == answers.count)

        // The spoken cues that make the session usable without looking (spec §62).
        let spoken = harness.synthesizer.japanese
        #expect(spoken.first == "今日は日常の日本語を練習しましょう。")
        #expect(spoken.contains("聞いてください。"))
        #expect(spoken.contains("あなたの番です。"))
        #expect(spoken.contains("今日の練習は終了です。"))
        #expect(spoken.last == "お疲れさまでした。")
        #expect(harness.feedback.cues.contains(.yourTurn))
        #expect(harness.feedback.cues.last == .sessionComplete)
    }

    @Test func recordsMistakesAndKnowledge() async throws {
        let harness = Harness(plan: plan, answers: answers)
        _ = try #require(await harness.runToCompletion())

        #expect(harness.repository.mistakes.contains { $0.type == .pastTense && $0.itemID == "e.past.tokyo" })
        let tokyo = try #require(harness.repository.knowledgeByID["e.past.tokyo"])
        #expect(tokyo.state(.spokenRecall).reviews == 1)
        #expect(tokyo.state(.spokenRecall).lapses == 1)
        let restaurant = try #require(harness.repository.knowledgeByID["e.restaurant.colleagues"])
        #expect(restaurant.state(.listening).strength > 0.5)
        #expect(harness.repository.sessions.count == 1)
    }

    @Test func givesCommunicationFirstFeedbackAndModelAnswer() async throws {
        let harness = Harness(plan: plan, answers: answers)
        _ = try #require(await harness.runToCompletion())
        let spoken = harness.synthesizer.japanese
        // After the mistake the learner hears the model sentence and is asked to try again.
        #expect(spoken.contains("例えば、こう言えます。"))
        #expect(spoken.contains("昨日、東京に行きました。"))
        #expect(spoken.contains("もう一度言ってみましょう。"))
    }

    @Test func survivesTotalSilence() async throws {
        let harness = Harness(plan: plan, answers: [])
        let summary = try #require(await harness.runToCompletion())
        #expect(summary.completedNormally)
        #expect(summary.results.allSatisfy { !$0.verdict.isSuccess })
        #expect(harness.synthesizer.japanese.contains("大丈夫です。"))
    }

    @Test func repeatCommandReplaysThePrompt() async throws {
        let single = SessionPlan(minutes: 2, focus: .speaking, track: nil, exercises: [.recall(itemID: "w.confirm.will")], closingItemID: nil)
        let harness = Harness(plan: single, answers: ["もう一度お願いします", "確認しておきます"])
        _ = try #require(await harness.runToCompletion())
        let prompt = "Your colleague asks about a document you're not sure of. Say: I'll check on that."
        #expect(harness.synthesizer.spoken.filter { $0.text == prompt }.count == 2)
        #expect(harness.repository.knowledgeByID["w.confirm.will"]?.state(.spokenRecall).lapses == 0)
    }

    @Test func skipCommandMovesOn() async throws {
        let twoItems = SessionPlan(minutes: 5, focus: .speaking, track: nil,
                                   exercises: [.recall(itemID: "w.confirm.will"), .recall(itemID: "w.otsukare")], closingItemID: nil)
        let harness = Harness(plan: twoItems, answers: ["スキップ", "お疲れさまです"])
        let summary = try #require(await harness.runToCompletion())
        #expect(summary.results.map(\.itemID) == ["w.otsukare"])
    }

    @Test func pauseAndResumeRestartTheCurrentExercise() async throws {
        let single = SessionPlan(minutes: 2, focus: .speaking, track: nil, exercises: [.recall(itemID: "w.otsukare")], closingItemID: nil)
        let harness = Harness(plan: single, answers: ["ちょっと待って", "お疲れさまです"])
        harness.runner.start()
        for _ in 0..<500 where !harness.runner.isPaused { try await Task.sleep(nanoseconds: 2_000_000) }
        #expect(harness.runner.isPaused)
        #expect(harness.events.contains(.activity(.paused)))

        harness.runner.resume()
        for _ in 0..<2_500 where harness.summary == nil { try await Task.sleep(nanoseconds: 2_000_000) }
        let summary = try #require(harness.summary)
        #expect(summary.results.first?.verdict == .natural)
    }

    @Test func stopEndsEarlyAndKeepsProgress() async throws {
        let harness = Harness(plan: plan, answers: answers)
        harness.recognizer.delay = 20_000_000
        harness.runner.start()
        for _ in 0..<500 where harness.repository.knowledgeByID.isEmpty { try await Task.sleep(nanoseconds: 1_000_000) }
        harness.runner.stop()
        for _ in 0..<2_500 where harness.summary == nil { try await Task.sleep(nanoseconds: 2_000_000) }
        let summary = try #require(harness.summary)
        #expect(!summary.completedNormally)
        #expect(harness.repository.sessions.count == 1)
    }

    @Test func preparerPlansFromRepositoryState() async throws {
        let library = try ContentLibrary.bundled()
        let repository = InMemoryLearnerRepository()
        repository.personal = [LearningItem(id: "p.1", japanese: "工程に遅れが出ています。", kana: "こうていにおくれがでています。",
                                            english: "The schedule is slipping.", track: .work, category: "heard", level: 2,
                                            promptEn: "Say: the schedule is slipping.", isPersonal: true)]
        let prepared = await SessionPreparer(library: library, repository: repository).prepare(minutes: 5, focus: .speaking, seed: 4)
        #expect(prepared.library.item(id: "p.1") != nil)
        #expect(prepared.plan.exercises.contains { $0.itemID == "p.1" })
    }
}
