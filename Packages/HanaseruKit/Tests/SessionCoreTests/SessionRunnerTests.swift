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
    var texts: [String] { spoken.map(\.text) }
    var japanese: [String] { spoken.filter { $0.language == .japanese }.map(\.text) }
    func count(_ text: String) -> Int { spoken.filter { $0.text == text }.count }
}

/// Answers each listen from a script ("" = silence); silence once the script runs out. Logs every window.
@MainActor
final class ScriptedRecognizer: SpeechRecognitionProvider {
    var script: [String]
    /// Simulated thinking time, so tests can act mid-session.
    var delay: UInt64 = 0
    var latency: TimeInterval = 1.5
    private(set) var listenCount = 0
    private(set) var timeouts: [TimeInterval] = []
    let processingDescription = "test"

    init(_ script: [String]) {
        self.script = script
    }

    func listen(_ options: ListenOptions, onPartial: @escaping @MainActor (String) -> Void) async -> ListenResult {
        listenCount += 1
        timeouts.append(options.startTimeout)
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        guard !script.isEmpty else { return .silence }
        let text = script.removeFirst()
        guard !text.isEmpty else { return .silence }
        onPartial(text)
        return ListenResult(transcript: text, confidence: 0.9, latency: latency, speakingDuration: 2, outcome: .speech)
    }

    func cancelListening() {}
}

@MainActor
final class RecordingFeedback: CueFeedbackProvider {
    private(set) var cues: [HapticCue] = []
    func play(_ cue: HapticCue) { cues.append(cue) }
}

@MainActor
final class EventLog {
    var events: [SessionEvent] = []
}

@MainActor
struct Harness {
    let library: ContentLibrary
    let synthesizer = FakeSynthesizer()
    let recognizer: ScriptedRecognizer
    let feedback = RecordingFeedback()
    let repository: InMemoryLearnerRepository
    let runner: SessionRunner
    var events: [SessionEvent] { eventLog.events }
    private let eventLog = EventLog()

    init(plan: SessionPlan, answers: [String], library: ContentLibrary? = nil,
         repository: InMemoryLearnerRepository = InMemoryLearnerRepository(), options: SessionOptions = SessionOptions()) {
        let content = library ?? (try! ContentLibrary.bundled())
        self.library = content
        self.repository = repository
        recognizer = ScriptedRecognizer(answers)
        runner = SessionRunner(
            plan: plan, library: content,
            voice: .init(synthesizer: synthesizer, recognizer: recognizer, feedback: feedback),
            ai: OfflineAIProvider(library: content), repository: repository, options: options
        )
        let log = eventLog
        runner.onEvent = { log.events.append($0) }
    }

    /// Starts the session and waits (up to ~5 s) for it to finish.
    func runToCompletion() async -> SessionSummary? {
        runner.start()
        for _ in 0..<2_500 {
            if let summary { return summary }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return summary
    }

    var summary: SessionSummary? {
        for event in events { if case .finished(let summary) = event { return summary } }
        return nil
    }
}

/// True when `needles` appear in `haystack` in this order (not necessarily adjacent).
func inOrder(_ haystack: [String], _ needles: [String]) -> Bool {
    var index = haystack.startIndex
    for needle in needles {
        guard let found = haystack[index...].firstIndex(of: needle) else { return false }
        index = haystack.index(after: found)
    }
    return true
}

func near(_ a: [TimeInterval], _ b: [TimeInterval]) -> Bool {
    a.count >= b.count && zip(a, b).allSatisfy { abs($0 - $1) < 0.001 }
}

// MARK: - A controlled line

enum Fixture {
    static let partner = "この橋脚について、何か問題がありますか？"
    static let model = "いいえ、特に問題はありません。"
    static let english = "No, there's no particular problem."

    /// One line with four chunks and a partner, independent of the bundled content.
    @MainActor
    static func library() -> ContentLibrary {
        let bundled = try! ContentLibrary.bundled()
        let item = LearningItem(
            id: "t.problem", japanese: model, kana: "いいえ、とくにもんだいはありません。", english: english,
            track: .work, category: "test", level: 2,
            acceptableResponses: ["いいえ特に問題はありません"], keyTerms: [KeyTermGroup(["問題", "もんだい"])],
            chunks: [Chunk(ja: "いいえ、", kana: "いいえ、"), Chunk(ja: "特に", kana: "とくに"),
                     Chunk(ja: "問題は", kana: "もんだいは"), Chunk(ja: "ありません。", kana: "ありません。")],
            cueEn: "Say: " + english,
            partner: PartnerLine(japanese: partner, kana: "このきょうきゃくについて、なにかもんだいがありますか？",
                                 english: "Is there any problem with this pier?", personaID: "p.sato")
        )
        return ContentLibrary(items: bundled.items + [item], vocabulary: bundled.vocabulary, grammar: bundled.grammar,
                              scenarios: bundled.scenarios, personas: bundled.personas, cues: bundled.cues)
    }

    /// A repository where t.problem has history that puts it at `level` (guided or cued).
    @MainActor
    static func repository(level: ScaffoldLevel) async -> InMemoryLearnerRepository {
        let repository = InMemoryLearnerRepository()
        let start = Date().addingTimeInterval(-86_400)
        let grade: ReviewGrade = level == .guided ? .again : .hard
        let state = ReviewScheduler().record(KnowledgeState(itemID: "t.problem", introducedAt: start),
                                             dimension: .spokenRecall, grade: grade, at: start)
        await repository.save(state)
        return repository
    }

    static let plan = SessionPlan(minutes: 2, focus: .speaking, track: nil,
                                  exercises: [.recall(itemID: "t.problem")], closingItemID: nil)
}

// MARK: - The say-it turn

@Suite("Say-it turn: teach before test, no re-asking")
@MainActor
struct SayItTurnTests {
    @Test func silenceAtGuidedGetsOneNudgeThenTheAnswer() async throws {
        let harness = Harness(plan: Fixture.plan, answers: ["", "", ""], library: Fixture.library(),
                              repository: await Fixture.repository(level: .guided))
        _ = try #require(await harness.runToCompletion())

        // Think (W/2 = 4.2 s), after the nudge (5.7 s), then one echo (5 s) — no third attempt.
        #expect(near(harness.recognizer.timeouts, [4.2, 5.7, 5.0]))
        // The start given away never stops at 「いいえ」: it runs on to the next chunk, and the nudge gives the one after.
        #expect(inOrder(harness.synthesizer.texts, [
            Fixture.partner, "Is there any problem with this pier?", "Say: " + Fixture.english, "It starts…", "いいえ、特に",
            "問題は…", "No problem — here it is:", Fixture.model, Fixture.english,
        ]))
        // A missed line never comes straight back; with nothing else in this session it waits for next time,
        // and is only echoed once more as the closing "one to keep".
        #expect(near(harness.recognizer.timeouts, [4.2, 5.7, 5.0, 5.0]))
        #expect(harness.recognizer.listenCount == 4)
        #expect(harness.summary?.phraseID == "t.problem")
        #expect(harness.synthesizer.count("Let's try saying it again.") == 0)
        #expect(harness.synthesizer.count("Listen once more.") == 0)
        #expect(harness.runner.ledgerViolations.isEmpty)
        #expect(harness.summary?.results.first?.outcome == .modelNeeded)
    }

    @Test func wrongAnswerGetsTheModelImmediately() async throws {
        let repository = InMemoryLearnerRepository()
        let start = Date().addingTimeInterval(-86_400)
        await repository.save(ReviewScheduler().record(KnowledgeState(itemID: "e.past.tokyo", introducedAt: start),
                                                       dimension: .spokenRecall, grade: .hard, at: start))
        let plan = SessionPlan(minutes: 2, focus: .speaking, track: nil, exercises: [.recall(itemID: "e.past.tokyo")], closingItemID: nil)
        let harness = Harness(plan: plan, answers: ["昨日、東京に行きます。", "昨日、東京に行きました。"], repository: repository)
        _ = try #require(await harness.runToCompletion())

        // The second listen is the 4 s echo after the model, not another attempt at the cue.
        #expect(harness.recognizer.timeouts.count >= 2)
        #expect(abs(harness.recognizer.timeouts[1] - 4.0) < 0.001)
        #expect(harness.synthesizer.texts.contains("Here's how to say it:"))
        #expect(harness.repository.mistakes.contains { $0.type == .pastTense })
        let knowledge = try #require(harness.repository.knowledgeByID["e.past.tokyo"])
        #expect(knowledge.state(.spokenRecall).lapses >= 1)
        #expect(harness.summary?.results.first?.outcome == .modelNeeded)
    }

    @Test func cleanAnswerIsConfirmedWithoutAnEcho() async throws {
        let harness = Harness(plan: Fixture.plan, answers: ["いいえ、特に問題はありません"], library: Fixture.library(),
                              repository: await Fixture.repository(level: .cued))
        _ = try #require(await harness.runToCompletion())
        #expect(harness.recognizer.listenCount == 1)
        #expect(harness.summary?.results.first?.outcome == .cleanFast)
        #expect(harness.synthesizer.spoken.contains { $0.text == Fixture.model && $0.rate == 1.0 })
        #expect(harness.feedback.cues.contains(.correct))
        #expect(harness.repository.knowledgeByID["t.problem"]?.state(.spokenRecall).reviews == 2)
    }

    @Test func englishIsAlwaysGivenBeforeAGuidedOrCuedListen() async throws {
        let harness = Harness(plan: Fixture.plan, answers: ["いいえ、特に問題はありません"], library: Fixture.library(),
                              repository: await Fixture.repository(level: .cued))
        _ = try #require(await harness.runToCompletion())
        #expect(harness.synthesizer.texts.contains("Say: " + Fixture.english))
        #expect(harness.events.contains { event in
            if case .focus(let info) = event { return info.lineID == "t.problem" && info.level == .cued }
            return false
        })
    }
}

@Suite("Help commands")
@MainActor
struct HelpCommandTests {
    func run(_ answers: [String], level: ScaffoldLevel = .cued) async throws -> Harness {
        let harness = Harness(plan: Fixture.plan, answers: answers, library: Fixture.library(),
                              repository: await Fixture.repository(level: level))
        _ = try #require(await harness.runToCompletion())
        return harness
    }

    @Test func answerGivesTheModelAndAnEcho() async throws {
        let harness = try await run(["答え", ""])
        #expect(near(harness.recognizer.timeouts, [3.7, 5.0]))
        #expect(harness.summary?.results.first?.outcome == .modelNeeded)
    }

    @Test func hintGivesTheNudgeNow() async throws {
        let harness = try await run(["ヒント", "いいえ、特に問題はありません"])
        #expect(near(harness.recognizer.timeouts, [3.7, 5.2]))
        #expect(harness.synthesizer.texts.contains("いいえ、特に…"))
        #expect(harness.summary?.results.first?.outcome == .hinted)
    }

    @Test func thirdRepeatGivesTheAnswer() async throws {
        let harness = try await run(["もう一度", "もう一度", "もう一度", ""])
        #expect(near(harness.recognizer.timeouts, [3.7, 3.7, 3.7, 5.0]))
        #expect(harness.summary?.results.first?.outcome == .modelNeeded)
    }

    @Test func waitAddsThinkTime() async throws {
        let harness = try await run(["ちょっと待って", "いいえ、特に問題はありません"])
        #expect(near(harness.recognizer.timeouts, [3.7, 11.7]))
        #expect(harness.summary?.results.first?.outcome?.isClean == true)
    }

    @Test func skipIsNotGraded() async throws {
        let harness = try await run(["スキップ"])
        #expect(harness.summary?.results.first?.outcome == .skipped)
        // Not graded: only the earlier history is there. And it isn't asked again straight away.
        #expect(harness.repository.knowledgeByID["t.problem"]?.state(.spokenRecall).reviews == 1)
        #expect(harness.recognizer.listenCount == 1)
    }

    @Test func fillerHoldsTheTurnWithoutPenalty() async throws {
        let harness = try await run(["えーと", "いいえ、特に問題はありません"])
        #expect(near(harness.recognizer.timeouts, [3.7, 4.0]))
        #expect(harness.summary?.results.first?.outcome?.isClean == true)
    }

    @Test func englishSpeechIsUnclearAndNotGraded() async throws {
        let harness = try await run(["hello"])
        #expect(harness.summary?.results.first?.outcome == .unclear)
        #expect(harness.synthesizer.texts.contains("I didn't quite catch that. Here it is:"))
        // Unclear speech isn't graded: only the earlier history is there.
        #expect(harness.repository.knowledgeByID["t.problem"]?.state(.spokenRecall).reviews == 1)
    }

    @Test func aMissedLineComesBackAfterSomethingElse() async throws {
        let plan = SessionPlan(minutes: 5, focus: .speaking, track: nil,
                               exercises: [.recall(itemID: "t.problem"), .shadowing(itemID: "w.confirm.will")],
                               closingItemID: nil)
        let harness = Harness(plan: plan, answers: ["", "", "", "", "", "いいえ、特に問題はありません"],
                              library: Fixture.library(), repository: await Fixture.repository(level: .cued))
        _ = try #require(await harness.runToCompletion())
        // S2 think, nudge, echo; the shadowing's two echoes; then the line again, one level easier (S1).
        #expect(near(harness.recognizer.timeouts, [3.7, 5.2, 5.0, 5.0, 5.0, 4.2]))
        let results = harness.summary?.results ?? []
        #expect(results.map(\.lineID) == ["t.problem", "w.confirm.will", "t.problem"])
        #expect(results.first?.outcome == .modelNeeded)
        #expect(results.last?.level == ScaffoldLevel.guided.rawValue)
        #expect(results.last?.outcome?.isClean == true)
    }

    @Test func externalHintFromTheHelpBar() async throws {
        let harness = Harness(plan: Fixture.plan, answers: ["", "いいえ、特に問題はありません"], library: Fixture.library(),
                              repository: await Fixture.repository(level: .cued))
        harness.recognizer.delay = 20_000_000
        harness.runner.start()
        for _ in 0..<500 where harness.recognizer.listenCount == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        harness.runner.command(.hint)
        for _ in 0..<2_500 where harness.summary == nil { try await Task.sleep(nanoseconds: 2_000_000) }
        #expect(harness.summary?.results.first?.outcome == .hinted)
    }

    @Test func pauseAndResumeRestartTheExercise() async throws {
        let harness = Harness(plan: Fixture.plan, answers: ["ストップ", "いいえ、特に問題はありません"], library: Fixture.library(),
                              repository: await Fixture.repository(level: .cued))
        harness.runner.start()
        for _ in 0..<500 where !harness.runner.isPaused { try await Task.sleep(nanoseconds: 2_000_000) }
        #expect(harness.runner.isPaused)
        harness.runner.resume()
        for _ in 0..<2_500 where harness.summary == nil { try await Task.sleep(nanoseconds: 2_000_000) }
        #expect(harness.summary?.results.first?.outcome?.isClean == true)
        #expect(harness.synthesizer.count(Fixture.partner) == 2)
        #expect(harness.synthesizer.count("Let's begin.") == 1)
    }

    @Test func practisingTheHelpPhraseIsNotAReplay() async throws {
        let plan = SessionPlan(minutes: 5, focus: .speaking, track: nil, exercises: [], closingItemID: nil)
        let harness = Harness(plan: plan, answers: ["もう一度お願いします", "ゆっくりお願いします"],
                              options: SessionOptions(includeHelpOnboarding: true))
        _ = try #require(await harness.runToCompletion())
        // Each help phrase is echoed once as a line; neither triggers a replay.
        #expect(harness.recognizer.listenCount == 2)
        #expect(harness.synthesizer.count("もう一度お願いします。") == 1)
        #expect(harness.feedback.cues.filter { $0 == .correct }.count == 2)
    }
}

// MARK: - Whole sessions

@Suite("Hands-free sessions")
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

    @Test func totalSilenceStillFinishesGracefully() async throws {
        let harness = Harness(plan: plan, answers: [])
        let summary = try #require(await harness.runToCompletion())
        #expect(summary.completedNormally)
        #expect(harness.runner.ledgerViolations.isEmpty)
        #expect(harness.synthesizer.texts.contains("No problem — here it is:"))
        #expect(harness.synthesizer.japanese.last == "お疲れさまでした。")
        #expect(harness.feedback.cues.last == .sessionComplete)
        // No re-ask anywhere: the retired cues are never spoken.
        for retired in ["Let's try saying it again.", "Listen once more.", "Your turn."] {
            #expect(harness.synthesizer.count(retired) == 0)
        }
    }

    @Test func screenplayComesBeforeThePerformance() async throws {
        let scene = SessionPlan(minutes: 5, focus: .conversation, track: .everyday,
                                exercises: [.conversation(scenarioID: "s.weekend.chat", turns: 3)], closingItemID: nil)
        let harness = Harness(plan: scene, answers: [])
        _ = try #require(await harness.runToCompletion())
        let library = harness.library
        let scenario = try #require(library.scenario(id: "s.weekend.chat"))
        let lines = library.lines(in: scenario, learnerName: "Swapnil")
        let texts = harness.synthesizer.texts
        // Every partner line is heard once in the screenplay and once in the performance — never re-asked.
        for line in lines { #expect(harness.synthesizer.count(line.partner?.japanese ?? "") == 2) }
        // The learner's own lines are given in English and Japanese before the first chance to speak.
        #expect(inOrder(texts, ["First, just listen to the whole conversation.", "You: " + lines[0].english, lines[0].japanese,
                                "Now the real thing. Nakamura-san starts."]))
        #expect(harness.runner.ledgerViolations.isEmpty)
    }

    @Test func completesAHandsFreeSessionWithAnswers() async throws {
        let answers = [
            "昨日、東京に行きました。", "昨日、東京に行きました。",   // introduce e.past.tokyo: two echoes
            "会社の人と行きました。",                               // listening
            "昨日、東京に行きました。",                             // e.past.tokyo comes back at S1 (guided)
            "確認しておきます。", "確認しておきます。",               // shadowing echoes
            "昨日、東京に行きました。",                             // and once more at S2 (cued)
            "友達と出かけました。", "はい、楽しかったです。", "まだ決めていません。", // performance
        ]
        let harness = Harness(plan: plan, answers: answers)
        let summary = try #require(await harness.runToCompletion())
        #expect(summary.completedNormally)
        #expect(summary.conversationTurns == 3)
        #expect(harness.runner.ledgerViolations.isEmpty)
        #expect(harness.repository.sessions.count == 1)
        #expect(harness.repository.knowledgeByID["e.restaurant.colleagues"]?.state(.listening).reviews == 1)
        #expect(summary.results.contains { $0.kind == .conversation && $0.outcome?.isClean == true })
    }

    @Test func newLinesAreTaughtThenRecalled() async throws {
        let single = SessionPlan(minutes: 2, focus: .speaking, track: nil, exercises: [.recall(itemID: "w.otsukare")], closingItemID: nil)
        let harness = Harness(plan: single, answers: ["お疲れさまです", "お疲れさまです", "お疲れさまです"])
        _ = try #require(await harness.runToCompletion())
        let item = try #require(harness.library.item(id: "w.otsukare"))
        let texts = harness.synthesizer.texts
        // Taught (English, then Japanese) before it is asked for at all. "(…)" in the English is read as a pause.
        #expect(inOrder(texts, [JapaneseText.speakableEnglish("You say: " + item.english), item.japanese]))
        #expect(harness.runner.ledgerViolations.isEmpty)
        let recall = harness.summary?.results.first { $0.lineID == "w.otsukare" }
        #expect(recall?.level == ScaffoldLevel.guided.rawValue)
    }

    @Test func stopEndsEarlyAndKeepsProgress() async throws {
        let harness = Harness(plan: plan, answers: ["昨日、東京に行きました。"])
        harness.recognizer.delay = 20_000_000
        harness.runner.start()
        for _ in 0..<500 where harness.recognizer.listenCount < 2 { try await Task.sleep(nanoseconds: 1_000_000) }
        harness.runner.stop()
        for _ in 0..<2_500 where harness.summary == nil { try await Task.sleep(nanoseconds: 2_000_000) }
        let summary = try #require(harness.summary)
        #expect(!summary.completedNormally)
        #expect(harness.repository.sessions.count == 1)
    }

    @Test(arguments: [2, 5, 10])
    func plannedSessionsNeverAskBeforeTeaching(minutes: Int) async throws {
        for focus in [SessionFocus.work, .everyday] {
            for seed in [UInt64(1), 2, 3] {
                let repository = InMemoryLearnerRepository()
                let library = try ContentLibrary.bundled()
                let prepared = await SessionPreparer(library: library, repository: repository)
                    .prepare(minutes: minutes, focus: focus, seed: seed)
                let harness = Harness(plan: prepared.plan, answers: [], library: prepared.library, repository: repository)
                let summary = try #require(await harness.runToCompletion())
                #expect(summary.completedNormally)
                #expect(harness.runner.ledgerViolations.isEmpty, "\(minutes) min \(focus) seed \(seed)")
            }
        }
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
