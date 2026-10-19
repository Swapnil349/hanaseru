import Foundation
import Testing
import LearningCore
import ConversationCore
@testable import SessionCore

@Suite("Never silent: lost speech is said again, and no voice call can hold the session")
@MainActor
struct SpeechGuardTests {
    let japanese = SpeechRequest(text: "いいえ、特に問題はありません。", language: .japanese)
    let english = SpeechRequest(text: "That's the end of the conversation.", language: .english)

    // MARK: - The rules

    @Test func speechThatEndsAtOnceMadeNoSound() {
        #expect(SpeechGuard.verdict(for: japanese, elapsed: 0.05) == .tooFast)
        #expect(SpeechGuard.verdict(for: english, elapsed: 0.1) == .tooFast)
    }

    @Test func speechThatTookItsTimeWasHeard() {
        let expected = SpeechGuard.expectedSpeakingTime(of: japanese)
        #expect(expected > 1)
        #expect(SpeechGuard.verdict(for: japanese, elapsed: expected) == .spoken)
        // Faster voices and quick speakers still count: only a fraction of the time is suspicious.
        #expect(SpeechGuard.verdict(for: japanese, elapsed: expected * 0.4) == .spoken)
        #expect(SpeechGuard.verdict(for: english, elapsed: 1.5) == .spoken)
    }

    @Test func shortWordsAreNeverJudgedByLength() {
        let yes = SpeechRequest(text: "はい。", language: .japanese)
        #expect(SpeechGuard.verdict(for: yes, elapsed: 0.01) == .spoken)
    }

    @Test func fasterSpeechIsExpectedToTakeLess() {
        var fast = japanese
        fast.rate = 1.5
        var slow = japanese
        slow.rate = 0.7
        #expect(SpeechGuard.expectedSpeakingTime(of: fast) < SpeechGuard.expectedSpeakingTime(of: japanese))
        #expect(SpeechGuard.expectedSpeakingTime(of: slow) > SpeechGuard.expectedSpeakingTime(of: japanese))
    }

    @Test func silentSpeechIsRetriedOnceAfterRecoveringThenLeftBehind() {
        #expect(SpeechGuard.nextStep(after: .spoken, attempt: 1) == .done)
        #expect(SpeechGuard.nextStep(after: .neverStarted, attempt: 1) == .recoverAndRetry)
        #expect(SpeechGuard.nextStep(after: .tooFast, attempt: 1) == .recoverAndRetry)
        #expect(SpeechGuard.nextStep(after: .tooFast, attempt: 2) == .giveUp)
        #expect(SpeechGuard.nextStep(after: .neverStarted, attempt: 2) == .giveUp)
        #expect(SpeechGuard.nextStep(after: .spoken, attempt: 2) == .done)
    }

    @Test func theDeadlinesLeaveRoomForARetryAndForWriting() {
        // Two late starts, a retry and the recovery between them fit inside the deadline.
        let expected = SpeechGuard.expectedSpeakingTime(of: japanese)
        #expect(SpeechGuard.deadline(for: japanese) > 2 * SpeechGuard.startTimeout + 2 * expected + 4)
        // A written answer may take 90 s.
        #expect(SpeechGuard.listenDeadline(for: ListenOptions(startTimeout: 10)) > 90)
        #expect(SpeechGuard.listenDeadline(for: ListenOptions(startTimeout: 120)) > 120)
    }

    // MARK: - The session

    let plan = SessionPlan(minutes: 10, focus: .conversation, track: .everyday,
                           exercises: [.conversation(scenarioID: "s.weekend.chat", turns: 10)], closingItemID: nil)

    @Test func aVoiceThatNeverFinishesIsLeftBehindByItself() async throws {
        let library = try ContentLibrary.bundled()
        let scenario = try #require(library.scenario(id: "s.weekend.chat"))
        let lines = library.lines(in: scenario, learnerName: "")
        let synthesizer = StuckSynthesizer(stuckOn: lines[0].partner?.japanese ?? "-")
        let runner = SessionRunner(plan: plan, library: library,
                                   voice: .init(synthesizer: synthesizer, recognizer: ScriptedRecognizer([]),
                                                feedback: RecordingFeedback()),
                                   ai: OfflineAIProvider(library: library), repository: InMemoryLearnerRepository(),
                                   options: SessionOptions(sceneMode: .conversationOnly))
        var issues: [String] = []
        runner.onEvent = { event in
            if case .voiceIssue(let message) = event { issues.append(message) }
        }
        runner.speechDeadline = { _ in 0.2 }
        runner.start()
        // Nobody touches anything: the session moves on to the next line on its own.
        let next = lines[1].partner?.japanese ?? "-"
        for _ in 0..<3_000 where !synthesizer.texts.contains(next) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(synthesizer.texts.contains(next))
        #expect(issues.contains { $0.hasPrefix("speech didn't end") })
        synthesizer.release()
        runner.stop()
    }

    @Test func aRecogniserThatNeverAnswersCountsAsSilence() async throws {
        let recognizer = HangingRecognizer()
        let synthesizer = FakeSynthesizer()
        let library = Fixture.library()
        let runner = SessionRunner(plan: Fixture.plan, library: library,
                                   voice: .init(synthesizer: synthesizer, recognizer: recognizer, feedback: RecordingFeedback()),
                                   ai: OfflineAIProvider(library: library),
                                   repository: await Fixture.repository(level: .cued))
        var summary: SessionSummary?
        var issues: [String] = []
        runner.onEvent = { event in
            if case .finished(let done) = event { summary = done }
            if case .voiceIssue(let message) = event { issues.append(message) }
        }
        runner.listenDeadline = { _ in 0.1 }
        runner.start()
        for _ in 0..<3_000 where summary == nil {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        // Every listen hung, yet the turn went on: the answer was given and the session finished.
        #expect(summary != nil)
        #expect(recognizer.listens >= 1)
        #expect(synthesizer.japanese.contains(Fixture.model))
        #expect(issues.contains { $0.hasPrefix("listening didn't end") })
        recognizer.release()
    }

    @Test func pausingDoesNotWaitForAStuckVoice() async throws {
        let library = try ContentLibrary.bundled()
        let scenario = try #require(library.scenario(id: "s.weekend.chat"))
        let lines = library.lines(in: scenario, learnerName: "")
        let synthesizer = StuckSynthesizer(stuckOn: lines[0].partner?.japanese ?? "-")
        let runner = SessionRunner(plan: plan, library: library,
                                   voice: .init(synthesizer: synthesizer, recognizer: ScriptedRecognizer([]),
                                                feedback: RecordingFeedback()),
                                   ai: OfflineAIProvider(library: library), repository: InMemoryLearnerRepository(),
                                   options: SessionOptions(sceneMode: .conversationOnly))
        runner.start()
        for _ in 0..<2_000 where !synthesizer.isStuck { try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(synthesizer.isStuck)
        runner.pause()
        runner.resume()
        // Play says the same line again at once, although the first attempt is still hanging.
        for _ in 0..<1_000 where synthesizer.texts.filter({ $0 == lines[0].partner?.japanese }).count < 2 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(synthesizer.texts.filter { $0 == lines[0].partner?.japanese }.count >= 2)
        synthesizer.release()
        runner.stop()
    }
}

/// A recogniser that never hands back the turn, ignoring cancellation, until released.
@MainActor
final class HangingRecognizer: SpeechRecognitionProvider {
    let processingDescription = "test"
    private(set) var listens = 0
    private var held: [CheckedContinuation<Void, Never>] = []

    func listen(_ options: ListenOptions, onPartial: @escaping @MainActor (String) -> Void) async -> ListenResult {
        listens += 1
        await withCheckedContinuation { held.append($0) }
        return .silence
    }

    func cancelListening() {}

    func release() {
        held.forEach { $0.resume() }
        held.removeAll()
    }
}
