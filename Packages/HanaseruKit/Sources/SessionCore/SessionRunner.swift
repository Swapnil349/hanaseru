import Foundation
import LearningCore
import ConversationCore

/// Options decided by the app for one session.
public struct SessionOptions: Sendable {
    /// Teach the hands-free help words (もう一度, ゆっくり, ヒント, 答え) before the first exercise.
    public var includeHelpOnboarding: Bool

    public init(includeHelpOnboarding: Bool = false) {
        self.includeHelpOnboarding = includeHelpOnboarding
    }
}

/// Runs a hands-free session built on one rule: teach before test.
///
/// Every line the learner says is first given in English and Japanese. Then they say it, with support
/// fading level by level (model → first chunk → English → intent → partner only). If they are stuck or
/// wrong they hear the answer, echo it once, and the session moves on — nothing is ever asked twice in a
/// row; a missed line comes back later, one level easier.
///
/// Everything essential is spoken, so the session works with the phone in a pocket. The screen mirrors
/// state through `onEvent`. Pause, skip and stop cancel the running task; learning data is saved as it
/// happens.
@MainActor
public final class SessionRunner {
    public struct Voice {
        public var synthesizer: SpeechSynthesisProvider
        public var recognizer: SpeechRecognitionProvider
        public var feedback: CueFeedbackProvider

        public init(synthesizer: SpeechSynthesisProvider, recognizer: SpeechRecognitionProvider, feedback: CueFeedbackProvider) {
            self.synthesizer = synthesizer
            self.recognizer = recognizer
            self.feedback = feedback
        }
    }

    /// A help request from outside the microphone (help bar tap, AirPods), applied at the next chance.
    enum PendingCommand: Equatable {
        case voice(VoiceCommand)
        /// AirPods "next" while it's the learner's turn: give the answer and move straight on.
        case answerAndNext
    }

    /// A line coming back later in the session at a given level.
    struct PendingRecall {
        var line: PracticeLine
        var level: ScaffoldLevel
        /// The exercise during which it was queued: it comes back after a later one.
        var queuedDuring: Int
        /// Never straight after the same line (a line that was just missed, or just said, isn't re-asked at once).
        var needsGap: Bool
    }

    /// Where the session is, so that a skip skips the right thing.
    enum Stage {
        case intro, onboarding, exercise, recall, closing
    }

    public let plan: SessionPlan
    public var onEvent: ((SessionEvent) -> Void)?
    public private(set) var isPaused = false
    public private(set) var isFinished = false
    /// Production turns that would have been asked before the line was taught. Always empty when the
    /// teach-before-test rule holds; the runner teaches the line instead and records it here.
    public internal(set) var ledgerViolations: [String] = []

    let library: ContentLibrary
    let voice: Voice
    let ai: AIProvider
    let repository: LearnerRepository
    let options: SessionOptions
    let now: () -> Date
    let evaluator = ResponseEvaluator()
    let scheduler = ReviewScheduler()

    var learner = LearnerSnapshot(name: "", difficulty: .starting)
    var task: Task<Void, Never>?
    var started = false
    var stage: Stage = .intro
    var learnerLoaded = false
    var introDone = false
    var onboardingDone = false
    var closingDone = false
    var nextExerciseIndex = 0
    var currentExerciseIndex = 0
    var pendingStartIndex: Int?
    var startedAt: Date?
    var pausedAt: Date?
    var pausedTotal: TimeInterval = 0
    var glossedCues: Set<CueKey> = []
    var pendingCommand: PendingCommand?
    var isListening = false

    // Teaching state.
    /// Lines whose English and Japanese have both been spoken this session (the exposure ledger).
    var exposed: Set<String> = []
    var introducedToday: Set<String> = []
    var pendingRecalls: [PendingRecall] = []
    var requeuedOnce: Set<String> = []
    var appearances: [String: Int] = [:]
    var glossedPartnerLines: Set<String> = []
    /// The line practised most recently (taught, asked or heard).
    var lastLineID: String?
    /// The learner tapped to see the hidden Japanese during this turn: it counts as help.
    var peekedThisTurn = false
    var worstLines: [String: PracticeLine] = [:]
    var worstOutcomes: [String: TurnOutcome] = [:]
    var cleanSincePraise = 0
    var unclearStreak = 0
    var micCheckDone = false
    var echoLaterSaid = false
    var noProblemSaid = false
    var takeYourTimeSaid = false

    // Metrics for the summary (meaningful metrics, not XP).
    var secondsListening = 0.0
    var secondsSpeaking = 0.0
    var conversationTurns = 0
    var results: [ExerciseResult] = []
    var mistakes: [MistakeObservation] = []
    var scenarioIDs: [String] = []
    var wentWell: [String] = []
    var toPractise: [String] = []
    var closingLine: PracticeLine?

    public init(plan: SessionPlan, library: ContentLibrary, voice: Voice, ai: AIProvider,
                repository: LearnerRepository, options: SessionOptions = SessionOptions(),
                now: @escaping () -> Date = { Date() }) {
        self.plan = plan
        self.library = library
        self.voice = voice
        self.ai = ai
        self.repository = repository
        self.options = options
        self.now = now
    }

    // MARK: - Control

    public func start() {
        guard !started else { return }
        started = true
        startedAt = now()
        launch(after: nil)
    }

    public func pause() {
        guard started, !isFinished, !isPaused else { return }
        isPaused = true
        pausedAt = now()
        task?.cancel()
        silenceVoice()
        emit(.activity(.paused))
    }

    public func resume() {
        guard isPaused, !isFinished else { return }
        if let pausedAt { pausedTotal += now().timeIntervalSince(pausedAt) }
        pausedAt = nil
        isPaused = false
        launch(after: task)
    }

    public func togglePause() {
        isPaused ? resume() : pause()
    }

    /// Skips what is playing now: the welcome, the help lesson, the exercise, a line coming back, or the closing.
    public func skip() {
        guard started, !isFinished else { return }
        switch stage {
        case .intro: introDone = true
        case .onboarding: onboardingDone = true
        case .exercise: pendingStartIndex = currentExerciseIndex + 1
        case .recall: break // already taken off the queue, so it just doesn't come back
        case .closing: closingDone = true
        }
        let previous = task
        previous?.cancel()
        silenceVoice()
        if isPaused {
            if let pausedAt { pausedTotal += now().timeIntervalSince(pausedAt) }
            pausedAt = nil
            isPaused = false
        }
        launch(after: previous)
    }

    /// Ends the session early. Progress so far is kept.
    public func stop() {
        guard started, !isFinished else { return }
        let previous = task
        previous?.cancel()
        task = nil
        silenceVoice()
        Task { [weak self] in
            await previous?.value
            await self?.finish(completed: false)
        }
    }

    /// A help request from the help bar or the headphones. During the learner's turn it interrupts the
    /// listen and is handled at once; otherwise it applies to the next turn.
    public func command(_ command: VoiceCommand) {
        guard started, !isFinished else { return }
        switch command {
        case .pause:
            pause()
            return
        case .skip where !isListening:
            skip()
            return
        default:
            break
        }
        pendingCommand = .voice(command)
        if isListening { voice.recognizer.cancelListening() }
    }

    /// Hear the prompt again (AirPods "previous track" or 「もう一度」).
    public func replay() {
        command(.repeatPrompt)
    }

    /// The learner looked at the hidden Japanese on screen; the current turn counts as helped.
    public func notePeek() {
        peekedThisTurn = true
    }

    /// AirPods "next track": during the learner's turn, give the answer and move on; otherwise skip.
    public func answerAndNext() {
        guard started, !isFinished else { return }
        if isListening {
            pendingCommand = .answerAndNext
            voice.recognizer.cancelListening()
        } else {
            skip()
        }
    }

    func takePendingCommand() -> PendingCommand? {
        let command = pendingCommand
        pendingCommand = nil
        return command
    }

    private func launch(after previous: Task<Void, Never>?) {
        task = Task { [weak self] in
            await previous?.value
            await self?.run()
        }
    }

    private func silenceVoice() {
        voice.synthesizer.stopSpeaking()
        voice.recognizer.cancelListening()
    }

    // MARK: - Main loop

    private func run() async {
        guard !isFinished, !Task.isCancelled else { return }
        if let pending = pendingStartIndex {
            nextExerciseIndex = max(nextExerciseIndex, pending)
            pendingStartIndex = nil
        }
        do {
            if !learnerLoaded {
                emit(.activity(.preparing))
                learner = await repository.snapshot()
                learnerLoaded = true
            }
            if !introDone {
                stage = .intro
                try await intro()
                introDone = true
            }
            if options.includeHelpOnboarding && !onboardingDone {
                stage = .onboarding
                try await runHelpOnboarding()
                onboardingDone = true
            }
            while nextExerciseIndex < plan.exercises.count {
                if timeIsUp() { break }
                currentExerciseIndex = nextExerciseIndex
                let exercise = plan.exercises[currentExerciseIndex]
                emit(.exerciseStarted(index: currentExerciseIndex, total: plan.exercises.count,
                                      kind: exercise.kind, title: title(for: exercise)))
                stage = .exercise
                emit(.step(""))
                if plan.exercises.count > 1 {
                    try await coach(.part, ["n": "\(currentExerciseIndex + 1)", "k": "\(plan.exercises.count)",
                                            "title": spokenTitle(for: exercise)])
                }
                try await perform(exercise)
                nextExerciseIndex = currentExerciseIndex + 1
                // A line taught or missed earlier comes back after at least one other exercise.
                if !timeIsUp() {
                    stage = .recall
                    try await runOnePendingRecall(queuedBefore: currentExerciseIndex)
                }
            }
            nextExerciseIndex = plan.exercises.count
            currentExerciseIndex = plan.exercises.count
            stage = .recall
            while !timeIsUp(reserve: 35) {
                guard try await runOnePendingRecall() else { break }
            }
            if !closingDone {
                stage = .closing
                try await closing()
                closingDone = true
            }
            await finish(completed: true)
        } catch {
            // Cancelled by pause / skip / stop. State is kept so the session can resume.
        }
    }

    func timeIsUp(reserve: TimeInterval = 20) -> Bool {
        guard let startedAt, !results.isEmpty else { return false }
        let elapsed = now().timeIntervalSince(startedAt) - pausedTotal
        return elapsed > Double(plan.minutes * 60) - reserve
    }

    private func perform(_ exercise: PlannedExercise) async throws {
        switch exercise {
        case .listening(let id):
            if let item = library.item(id: id) { try await runListening(item) }
        case .recall(let id):
            if let item = library.item(id: id) { try await runRecall(item) }
        case .shadowing(let id):
            if let item = library.item(id: id) { try await runShadowing(item) }
        case .conversation(let id, let turns):
            try await runConversation(scenarioID: id, maxTurns: turns)
        }
    }

    private func title(for exercise: PlannedExercise) -> String {
        switch exercise {
        case .listening: "Listen and answer"
        case .recall: "Say it"
        case .shadowing: "Say it with me"
        case .conversation(let id, _): library.scenario(id: id)?.title ?? "Conversation"
        }
    }

    /// How a part is announced: "Part 2 of 4: a listening check."
    private func spokenTitle(for exercise: PlannedExercise) -> String {
        switch exercise {
        case .listening: "a listening check"
        case .recall: "a phrase"
        case .shadowing: "say it with me"
        case .conversation(let id, _): "a scene, " + (library.scenario(id: id)?.title ?? "a conversation")
        }
    }

    /// "3 phrases, a listening check and a scene, Inspection at the pier"
    func agenda() -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        var scenes: [String] = []
        for exercise in plan.exercises {
            let key: String
            switch exercise {
            case .listening: key = "listening"
            case .recall: key = "recall"
            case .shadowing: key = "shadowing"
            case .conversation(let id, _):
                key = "scene"
                scenes.append(library.scenario(id: id)?.title ?? "a conversation")
            }
            if counts[key] == nil { order.append(key) }
            counts[key, default: 0] += 1
        }
        let parts = order.map { key -> String in
            let count = counts[key] ?? 1
            switch key {
            case "listening": return count == 1 ? "a listening check" : "\(count) listening checks"
            case "recall": return count == 1 ? "a phrase" : "\(count) phrases"
            case "shadowing": return count == 1 ? "one line to say with me" : "\(count) lines to say with me"
            default: return (scenes.count == 1 ? "a scene, " : "scenes: ") + scenes.joined(separator: " and ")
            }
        }
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + (parts.last ?? "")
    }

    // MARK: - Intro and finish

    private func intro() async throws {
        let key: CueKey = switch plan.track {
        case .work: .sessionStartWork
        case .everyday: .sessionStartEveryday
        case nil: .sessionStartGeneral
        }
        try await coach(key)
        let agenda = agenda()
        if !agenda.isEmpty {
            emit(.line(ScriptLine(role: .instruction, japanese: "", english: "Today: " + agenda)))
            try await coach(.agenda, ["agenda": agenda])
        }
    }

    func finish(completed: Bool) async {
        guard !isFinished else { return }
        isFinished = true
        let summary = SessionSummary(
            startedAt: startedAt ?? now(), endedAt: now(), plannedMinutes: plan.minutes, focus: plan.focus,
            secondsListening: secondsListening, secondsSpeaking: secondsSpeaking, results: results,
            conversationTurns: conversationTurns, scenarioIDs: scenarioIDs, mistakes: mistakes,
            wentWell: Array(unique(wentWell).prefix(3)), toPractise: Array(unique(toPractise).prefix(3)),
            phraseID: closingLine?.id, phraseJapanese: closingLine?.japanese ?? "", phraseEnglish: closingLine?.english ?? "",
            completedNormally: completed
        )
        let recent = await repository.recentResults(limit: 30)
        let adapted = DifficultyAdapter().adapted(learner.difficulty, recent: recent + results)
        if adapted != learner.difficulty { await repository.saveDifficulty(adapted) }
        await repository.record(summary)
        emit(.activity(.finished))
        emit(.finished(summary))
    }

    func emit(_ event: SessionEvent) {
        onEvent?(event)
    }

    func reportAIHealth() {
        if let resilient = ai as? ResilientAIProvider {
            emit(.aiDegraded(resilient.lastFailure != nil))
        }
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
