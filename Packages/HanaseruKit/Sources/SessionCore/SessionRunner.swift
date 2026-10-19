import Foundation
import LearningCore
import ConversationCore

/// How much of a scene lesson to play.
public enum SceneMode: String, CaseIterable, Sendable {
    /// The full lesson the first time; straight to the conversation once the scene has been practised.
    case automatic
    /// Brief, listen to the whole conversation, practise each line, then the conversation.
    case fullLesson
    /// Practise each line, then the conversation.
    case practiseLines
    /// Just the conversation: no explanations.
    case conversationOnly
    /// Watch the characters act out the whole conversation; nothing is asked.
    case watch
}

/// When the Japanese of the learner's own line is on screen before they say it.
public enum AnswerDisplay: String, CaseIterable, Sendable {
    /// While the line is being learned (S0–S2) it is there to read; once it's known (S3 on) it is hidden
    /// until the turn is over, and can be tapped to see.
    case whileLearning
    /// Always on screen. From S3 on, a turn with the answer in view counts as helped.
    case always
    /// Only after the turn (at S1, just the start of the line).
    case afterTurn
}

/// Moving through a session: ⏮ ↺ ⏭ and starting from a line of the script.
public enum SessionMove: Equatable, Sendable {
    /// The line before (from the first line of a part: the start of the part before).
    case previous
    /// This line again, from its beginning.
    case again
    /// The next line (from the last line of a part: the next part).
    case next
    /// A part of the session and, in a scene, one of its lines (counted from the scene's first line).
    case to(part: Int, line: Int?)
    /// A stop of the scene's timeline (the scrubber): a line's question, or straight to its answer.
    case seek(Int)
}

/// Options decided by the app for one session.
public struct SessionOptions: Sendable {
    /// Teach the hands-free help words (もう一度, ゆっくり, ヒント, 答え) before the first exercise.
    public var includeHelpOnboarding: Bool
    public var sceneMode: SceneMode
    /// Start scenes at this beat (0 = the beginning).
    public var sceneStartBeat: Int
    /// A practised learner: skip the spoken plan at the start.
    public var briefIntro: Bool
    public var answerDisplay: AnswerDisplay
    /// In scenes, the learner plays the colleague and the app says the learner's usual lines.
    public var playAsPartner: Bool
    /// Start at this place of the timeline (where the learner stopped last time).
    public var resumeAt: SessionTimeline.Stop?
    /// No time limit: a scene chosen by the learner plays to its end however long it takes.
    public var untimed: Bool

    public init(includeHelpOnboarding: Bool = false, sceneMode: SceneMode = .automatic, sceneStartBeat: Int = 0,
                briefIntro: Bool = false, answerDisplay: AnswerDisplay = .whileLearning, playAsPartner: Bool = false,
                resumeAt: SessionTimeline.Stop? = nil, untimed: Bool = false) {
        self.includeHelpOnboarding = includeHelpOnboarding
        self.sceneMode = sceneMode
        self.sceneStartBeat = sceneStartBeat
        self.briefIntro = briefIntro
        self.answerDisplay = answerDisplay
        self.playAsPartner = playAsPartner
        self.resumeAt = resumeAt
        self.untimed = untimed
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
/// state through `onEvent`. Pause, the moves (⏮ ↺ ⏭) and stop cancel the running task; the session keeps
/// its place line by line, so it carries on from the same line. Learning data is saved as it happens.
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

    // The place inside the current part, so that pause and the moves work one line at a time.
    /// The segment being played (a scene has one per line and step; other parts have one).
    var cursor = 0
    /// The part `cursor` belongs to.
    var cursorPart = -1
    var segmentCount = 1
    var sceneState: SceneState?
    /// A scene line chosen in the script, for the part about to start.
    var pendingLine: Int?
    var announcedPart = -1
    /// ↺ (or a line coming back, replayed): the line in progress plays again, so it isn't recorded or dropped.
    var replayingCurrent = false
    /// The learner chose a part themselves: it plays even when the planned time is up.
    var userChosePart = false
    /// A line coming back was paused or replayed: it plays before anything else.
    var interruptedRecall = false
    /// The scene segment being played starts at its answer (chosen on the scrubber).
    var answerFirst = false
    /// Inside a scene, after its one explanation, the coach speaks Japanese only; the English is on screen.
    var japaneseOnly = false

    // The scrubber over the whole session.
    var sessionStops: [SessionTimeline.Stop] = []
    var sessionTargets: [SessionTarget] = []
    /// Where each part's stops begin in `sessionStops`.
    var partOffsets: [Int] = []
    /// Every scene part, worked out at the start so the scrubber covers the whole session.
    var sceneStates: [Int: SceneState] = [:]
    var timelineBuilt = false
    /// For a part about to start: the segment, and whether at its answer, chosen on the scrubber.
    var pendingSegment: Int?
    var pendingAnswer = false

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

    /// The longest the session waits for one utterance or one listen before it moves on without it, so a voice
    /// that never comes back can't leave it silent (tests shorten these).
    var speechDeadline: (SpeechRequest) -> TimeInterval = SpeechGuard.deadline(for:)
    var listenDeadline: (ListenOptions) -> TimeInterval = SpeechGuard.listenDeadline(for:)

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

    /// Carries on from the line that was playing when the session was paused (from its beginning).
    public func resume() {
        guard isPaused, !isFinished else { return }
        if let pausedAt { pausedTotal += now().timeIntervalSince(pausedAt) }
        pausedAt = nil
        isPaused = false
        // Stops a line being played on request first.
        let previous = task
        previous?.cancel()
        voice.synthesizer.stopSpeaking()
        launch(after: previous)
    }

    public func togglePause() {
        isPaused ? resume() : pause()
    }

    /// ⏭: the next line, or past what is playing now (the welcome, the help lesson, a line coming back, the closing).
    public func skip() {
        move(.next)
    }

    /// ⏮ ↺ ⏭, or a line chosen in the script. Works while playing or paused; playing carries on from there.
    public func move(_ move: SessionMove) {
        guard started, !isFinished else { return }
        replayingCurrent = false
        answerFirst = false
        sceneState?.lastOutcome = nil
        switch move {
        case .again:
            replayingCurrent = true
        case .previous:
            if stage == .exercise && cursor > 0 {
                cursor -= 1
            } else if stage == .exercise && currentExerciseIndex > 0 {
                pendingStartIndex = currentExerciseIndex - 1
                userChosePart = true
            } else {
                // Nothing before it in this part: the welcome, the help lesson, a line coming back or the
                // closing starts again.
                replayingCurrent = true
            }
        case .next:
            switch stage {
            case .intro: introDone = true
            case .onboarding: onboardingDone = true
            case .exercise:
                if cursor + 1 < segmentCount {
                    cursor += 1
                } else {
                    pendingStartIndex = currentExerciseIndex + 1
                }
            case .recall: break // already taken off the queue, so it just doesn't come back
            case .closing: closingDone = true
            }
        case .to(let part, let line):
            guard plan.exercises.indices.contains(part) else { return }
            introDone = true
            onboardingDone = true
            if stage == .exercise, part == currentExerciseIndex, let line,
               let target = sceneState?.segmentIndex(forLine: line, near: cursor) {
                cursor = target
            } else {
                pendingStartIndex = part
                pendingLine = line
                cursorPart = -1
                userChosePart = true
            }
        case .seek(let stop):
            guard sessionTargets.indices.contains(stop) else { return }
            let target = sessionTargets[stop]
            introDone = true
            onboardingDone = true
            if stage == .exercise && target.part == currentExerciseIndex {
                cursor = target.segment
                answerFirst = target.answer
            } else {
                pendingStartIndex = target.part
                pendingSegment = target.segment
                pendingAnswer = target.answer
                cursorPart = -1
                userChosePart = true
            }
        }
        restart()
    }

    /// Plays lines on request — the speaker buttons and the script — as often as the learner likes. The
    /// session pauses first so nothing overlaps; play carries on from the same line.
    public func listen(to requests: [SpeechRequest]) {
        guard started, !isFinished, !requests.isEmpty else { return }
        if !isPaused { pause() }
        let previous = task
        previous?.cancel()
        voice.synthesizer.stopSpeaking()
        task = Task { [weak self] in
            await previous?.value
            await self?.playOnRequest(requests)
        }
    }

    private func playOnRequest(_ requests: [SpeechRequest]) async {
        for request in requests {
            // English with Japanese in 「」 is spoken by two voices, as in the session.
            let parts: [SpeechRequest] = request.language == .japanese ? [request]
                : JapaneseText.bilingualSegments(request.text).map { segment in
                    segment.isJapanese
                        ? SpeechRequest(text: segment.text, language: .japanese, rate: 0.9, pauseAfter: 0.1, voice: .coachJapanese)
                        : SpeechRequest(text: JapaneseText.speakableEnglish(segment.text), language: .english, pauseAfter: 0.1)
                }
            for part in parts {
                guard !Task.isCancelled else { return }
                await say(part)
            }
        }
    }

    /// The line in progress will be played again (paused, or ↺), so it isn't recorded or dropped.
    var redoesCurrentLine: Bool { isPaused || replayingCurrent }

    private func restart() {
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
            if let previous { await Self.settle(previous) }
            await self?.run()
        }
    }

    /// Waits for a cancelled task to wind down, but never long: a voice call that ignores cancellation must
    /// not freeze the session.
    static func settle(_ previous: Task<Void, Never>, within seconds: Double = 1.5) async {
        let gate = Gate()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gate.continuation = continuation
            Task { @MainActor in
                await previous.value
                gate.open()
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                gate.open()
            }
        }
    }

    /// Resumes a waiting task once, whichever comes first.
    final class Gate {
        var continuation: CheckedContinuation<Void, Never>?

        func open() {
            continuation?.resume()
            continuation = nil
        }
    }

    /// Runs a voice call, but returns `fallback` once `seconds` have passed or the calling task is cancelled,
    /// whichever comes first. The call itself is cancelled and left to wind down on its own: one that ignores
    /// cancellation (an audio framework that hangs) can't hold the session.
    static func bounded<T: Sendable>(_ seconds: TimeInterval, fallback: T,
                                     _ operation: @escaping @MainActor () async -> T) async -> T {
        let box = BoundedResult<T>()
        let work = Task { @MainActor in box.finish(await operation()) }
        let timer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            box.finish(fallback)
        }
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
                box.wait(continuation)
            }
        } onCancel: {
            work.cancel()
            Task { @MainActor in box.finish(fallback) }
        }
        timer.cancel()
        return result
    }

    /// The first value wins; a waiter set before or after it gets that value exactly once. Only used on the
    /// main actor.
    final class BoundedResult<T>: @unchecked Sendable {
        private var value: T?
        private var continuation: CheckedContinuation<T, Never>?
        private var done = false

        func wait(_ continuation: CheckedContinuation<T, Never>) {
            if let value {
                continuation.resume(returning: value)
            } else {
                self.continuation = continuation
            }
        }

        func finish(_ result: T) {
            guard !done else { return }
            done = true
            if let continuation {
                self.continuation = nil
                continuation.resume(returning: result)
            } else {
                value = result
            }
        }
    }

    /// Says one utterance, never waiting past its deadline.
    func say(_ request: SpeechRequest) async {
        let synthesizer = voice.synthesizer
        let limit = speechDeadline(request)
        let finished = await Self.bounded(limit, fallback: false) {
            await synthesizer.speak(request)
            return true
        }
        guard !finished, !Task.isCancelled else { return }
        synthesizer.stopSpeaking()
        emit(.voiceIssue("speech didn't end within \(Int(limit)) s, moved on: \(request.text.prefix(40))"))
    }

    /// One listen, never waiting past its deadline: a recogniser that never hands back the turn counts as silence.
    func hear(_ options: ListenOptions, onPartial: @escaping @MainActor (String) -> Void) async -> ListenResult {
        let recognizer = voice.recognizer
        let limit = listenDeadline(options)
        let result = await Self.bounded(limit, fallback: ListenResult?.none) {
            Optional(await recognizer.listen(options, onPartial: onPartial))
        }
        if let result { return result }
        if !Task.isCancelled {
            recognizer.cancelListening()
            emit(.voiceIssue("listening didn't end within \(Int(limit)) s; the turn goes on without an answer"))
        }
        return .silence
    }

    /// Listens for the learner saying one line of the script ("Say it"). The session pauses first; returns
    /// what was heard and how close it is to the line (0…1).
    public func sayLine(_ references: [String]) async -> (heard: String, similarity: Double) {
        guard started, !isFinished, !references.isEmpty else { return ("", 0) }
        if !isPaused { pause() }
        task?.cancel()
        voice.synthesizer.stopSpeaking()
        // The microphone is free once the paused turn has wound down.
        if let task { await Self.settle(task) }
        voice.feedback.play(.yourTurn)
        let options = ListenOptions(startTimeout: 6, endSilence: 1.2, maxDuration: 15, contextualStrings: references)
        let result = await hear(options) { _ in }
        let heard = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return (heard, heard.isEmpty ? 0 : JapaneseText.bestSimilarity(heard, to: references))
    }

    private func silenceVoice() {
        voice.synthesizer.stopSpeaking()
        voice.recognizer.cancelListening()
    }

    // MARK: - Main loop

    private func run() async {
        guard !isFinished, !Task.isCancelled else { return }
        replayingCurrent = false
        if let pending = pendingStartIndex {
            nextExerciseIndex = pending
            pendingStartIndex = nil
        }
        do {
            if !learnerLoaded {
                emit(.activity(.preparing))
                learner = await repository.snapshot()
                learnerLoaded = true
            }
            if !timelineBuilt {
                timelineBuilt = true
                await buildTimeline()
                // Where the learner stopped last time.
                if let point = options.resumeAt, let index = stopIndex(matching: point) {
                    let target = sessionTargets[index]
                    nextExerciseIndex = target.part
                    pendingSegment = target.segment
                    pendingAnswer = target.answer
                    userChosePart = true
                }
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
            if interruptedRecall {
                interruptedRecall = false
                stage = .recall
                try await runOnePendingRecall()
            }
            while nextExerciseIndex < plan.exercises.count {
                if timeIsUp() && !userChosePart { break }
                userChosePart = false
                currentExerciseIndex = nextExerciseIndex
                var startLine: Int?
                if cursorPart != currentExerciseIndex {
                    // A new part starts at its beginning (or at the line chosen in the script). Resuming the
                    // same part keeps its place.
                    cursorPart = currentExerciseIndex
                    cursor = pendingSegment ?? 0
                    answerFirst = pendingAnswer
                    segmentCount = 1
                    sceneState = nil
                    startLine = pendingLine
                }
                pendingLine = nil
                pendingSegment = nil
                pendingAnswer = false
                japaneseOnly = false
                emit(.stage(nil))
                if sceneStates[currentExerciseIndex] == nil { showPosition(local: answerFirst ? 1 : 0) }
                let exercise = plan.exercises[currentExerciseIndex]
                emit(.exerciseStarted(index: currentExerciseIndex, total: plan.exercises.count,
                                      kind: exercise.kind, title: title(for: exercise)))
                stage = .exercise
                emit(.step(""))
                if plan.exercises.count > 1 && announcedPart != currentExerciseIndex {
                    try await coach(.part, ["n": "\(currentExerciseIndex + 1)", "k": "\(plan.exercises.count)",
                                            "title": spokenTitle(for: exercise)])
                    announcedPart = currentExerciseIndex
                }
                try await perform(exercise, startLine: startLine)
                japaneseOnly = false
                try Task.checkCancellation()
                answerFirst = false
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
        guard !options.untimed, let startedAt, !results.isEmpty else { return false }
        let elapsed = now().timeIntervalSince(startedAt) - pausedTotal
        return elapsed > Double(plan.minutes * 60) - reserve
    }

    private func perform(_ exercise: PlannedExercise, startLine: Int?) async throws {
        switch exercise {
        case .listening(let id):
            if let item = library.item(id: id) { try await runListening(item) }
        case .recall(let id):
            if let item = library.item(id: id) { try await runRecall(item) }
        case .shadowing(let id):
            if let item = library.item(id: id) { try await runShadowing(item) }
        case .conversation(let id, let turns):
            try await runConversation(scenarioID: id, maxTurns: turns, startLine: startLine)
        }
    }

    func title(for exercise: PlannedExercise) -> String {
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
        if !agenda.isEmpty && !options.briefIntro {
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
