import Foundation
import LearningCore
import ConversationCore

/// Runs a hands-free session: LISTEN → THINK → RESPOND → FEEDBACK → TRY AGAIN (spec §2, §24–27).
///
/// Everything the learner needs is spoken, so the session works with the phone in a pocket (spec §62).
/// The screen only mirrors state through `onEvent`.
///
/// Pause, skip and stop cancel the running task; the current exercise restarts on resume. Learning
/// data (knowledge, mistakes) is saved as it happens so nothing is lost if the session ends early.
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

    public let plan: SessionPlan
    public var onEvent: ((SessionEvent) -> Void)?
    public private(set) var isPaused = false
    public private(set) var isFinished = false

    private let library: ContentLibrary
    private let voice: Voice
    private let ai: AIProvider
    private let repository: LearnerRepository
    private let now: () -> Date
    private let evaluator = ResponseEvaluator()
    private let scheduler = ReviewScheduler()

    private var learner = LearnerSnapshot(name: "", difficulty: .starting)
    private var task: Task<Void, Never>?
    private var started = false
    private var introDone = false
    private var closingDone = false
    private var nextExerciseIndex = 0
    private var currentExerciseIndex = 0
    private var pendingStartIndex: Int?
    private var startedAt: Date?
    private var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0
    private var glossedCues: Set<CueKey> = []

    // Metrics for the summary (spec §52: meaningful metrics, not XP).
    private var secondsListening = 0.0
    private var secondsSpeaking = 0.0
    private var conversationTurns = 0
    private var results: [ExerciseResult] = []
    private var mistakes: [MistakeObservation] = []
    private var scenarioIDs: [String] = []
    private var wentWell: [String] = []
    private var toPractise: [String] = []
    private var closingItem: LearningItem?

    public init(plan: SessionPlan, library: ContentLibrary, voice: Voice, ai: AIProvider,
                repository: LearnerRepository, now: @escaping () -> Date = { Date() }) {
        self.plan = plan
        self.library = library
        self.voice = voice
        self.ai = ai
        self.repository = repository
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

    /// Skips the current exercise (AirPods "next track", or saying 「スキップ」).
    public func skip() {
        guard started, !isFinished else { return }
        pendingStartIndex = currentExerciseIndex + 1
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
            // Skipping during the closing phrase ends the session.
            if pending > plan.exercises.count { closingDone = true }
        }
        do {
            if !introDone {
                emit(.activity(.preparing))
                learner = await repository.snapshot()
                try await intro()
                introDone = true
            }
            while nextExerciseIndex < plan.exercises.count {
                if timeIsUp() { break }
                currentExerciseIndex = nextExerciseIndex
                let exercise = plan.exercises[currentExerciseIndex]
                emit(.exerciseStarted(index: currentExerciseIndex, total: plan.exercises.count,
                                      kind: exercise.kind, title: title(for: exercise)))
                try await perform(exercise)
                nextExerciseIndex = currentExerciseIndex + 1
            }
            nextExerciseIndex = plan.exercises.count
            currentExerciseIndex = plan.exercises.count
            if !closingDone {
                try await closing()
                closingDone = true
            }
            await finish(completed: true)
        } catch {
            // Cancelled by pause / skip / stop. State is kept so the session can resume.
        }
    }

    private func timeIsUp() -> Bool {
        guard let startedAt, !results.isEmpty else { return false }
        let elapsed = now().timeIntervalSince(startedAt) - pausedTotal
        return elapsed > Double(plan.minutes * 60) - 20
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
        case .listening: "What did they say?"
        case .recall: "Say it naturally"
        case .shadowing: "Shadowing"
        case .conversation(let id, _): library.scenario(id: id)?.title ?? "Conversation"
        }
    }

    // MARK: - Intro and closing

    private func intro() async throws {
        let key: CueKey = switch plan.track {
        case .work: .sessionStartWork
        case .everyday: .sessionStartEveryday
        case nil: .sessionStartGeneral
        }
        try await cue(key)
    }

    /// 「今日の練習は終了です。」 + one phrase to remember, repeated once (spec §89).
    private func closing() async throws {
        try await cue(.sessionEnd)
        if let id = plan.closingItemID, let item = library.item(id: id) {
            closingItem = item
            try await cue(.onePhrase)
            if learner.difficulty.usesEnglishPrompts { try await speak(item.english, .english) }
            try await sayJapanese(item.japanese, kana: item.kana, english: item.english, role: .coach, rate: 0.85)
            try await cue(.repeatAfterMe)
            let replay: () async throws -> Void = {
                try await self.sayJapanese(item.japanese, kana: item.kana, english: item.english, role: .coach, rate: 0.85)
            }
            if let attempt = try await awaitAnswer(expecting: [item.japanese], announce: false, replay: replay),
               JapaneseText.bestSimilarity(attempt.transcript, to: [item.japanese, item.kana]) >= 0.75 {
                voice.feedback.play(.correct)
                try await cue(.good)
            }
        }
        try await cue(.wellDone)
        voice.feedback.play(.sessionComplete)
    }

    private func finish(completed: Bool) async {
        guard !isFinished else { return }
        isFinished = true
        let summary = SessionSummary(
            startedAt: startedAt ?? now(), endedAt: now(), plannedMinutes: plan.minutes, focus: plan.focus,
            secondsListening: secondsListening, secondsSpeaking: secondsSpeaking, results: results,
            conversationTurns: conversationTurns, scenarioIDs: scenarioIDs, mistakes: mistakes,
            wentWell: Array(unique(wentWell).prefix(3)), toPractise: Array(unique(toPractise).prefix(3)),
            phraseID: closingItem?.id, phraseJapanese: closingItem?.japanese ?? "", phraseEnglish: closingItem?.english ?? "",
            completedNormally: completed
        )
        let recent = await repository.recentResults(limit: 30)
        let adapted = DifficultyAdapter().adapted(learner.difficulty, recent: recent + results)
        if adapted != learner.difficulty { await repository.saveDifficulty(adapted) }
        await repository.record(summary)
        emit(.activity(.finished))
        emit(.finished(summary))
    }

    // MARK: - Listening: "What did they say?" (spec §38, §81)

    private func runListening(_ item: LearningItem) async throws {
        guard let check = item.listening else { return }
        let rate = learner.difficulty.speechRate
        let partner = LineRole.partner(name: "")

        try await cue(.listen)
        try await sayJapanese(item.japanese, kana: item.kana, english: "", role: partner, rate: rate, show: false)
        try await cue(.question)
        try await sayJapanese(check.questionJa, kana: "", english: check.questionEn, role: .coach, rate: rate)
        if learner.difficulty.englishSupport >= 0.6 { try await speak(check.questionEn, .english) }

        let replay: () async throws -> Void = {
            try await self.sayJapanese(item.japanese, kana: item.kana, english: "", role: partner, rate: rate, show: false)
            try await self.sayJapanese(check.questionJa, kana: "", english: check.questionEn, role: .coach, rate: rate)
        }
        let expected = check.answerTerms.flatMap(\.anyOf)
        guard let first = try await awaitAnswer(expecting: expected, announce: true, replay: replay) else { return }
        let target = EvaluationTarget(listening: check)
        let firstVerdict = evaluator.evaluate(first.transcript, against: target).verdict
        var finalVerdict = firstVerdict
        var heard = first.transcript

        if !firstVerdict.isSuccess {
            // One more listen, slower (spec §38: slow → normal → natural).
            voice.feedback.play(.tryAgain)
            try await cue(.listenAgain)
            try await sayJapanese(item.japanese, kana: item.kana, english: "", role: partner, rate: max(0.7, rate - 0.15), show: false)
            try await sayJapanese(check.questionJa, kana: "", english: check.questionEn, role: .coach, rate: rate)
            if let second = try await awaitAnswer(expecting: expected, announce: false, replay: replay) {
                finalVerdict = evaluator.evaluate(second.transcript, against: target).verdict
                heard = second.transcript
            }
        }

        if finalVerdict.isSuccess {
            voice.feedback.play(.correct)
            emit(.feedback(FeedbackNote(verdict: finalVerdict, headline: "You caught it", suggestion: check.modelAnswer, heard: heard)))
            try await cue(.good)
        } else {
            emit(.feedback(FeedbackNote(verdict: finalVerdict, headline: "Here's the answer", detail: check.questionEn,
                                        suggestion: check.modelAnswer, heard: heard)))
            try await cue(.modelAnswer)
            try await sayJapanese(check.modelAnswer, kana: "", english: "", role: .coach, rate: rate)
        }
        // Reveal the sentence only after the attempt (spec §81).
        emit(.line(ScriptLine(role: partner, japanese: item.japanese, kana: item.kana, english: item.english)))
        if learner.difficulty.usesEnglishPrompts { try await speak(item.english, .english) }

        await updateKnowledge(item, .listening, verdict: firstVerdict, latency: first.latency)
        if firstVerdict.isSuccess { await updateKnowledge(item, .recognition, verdict: firstVerdict, latency: nil) }
        recordResult(.listening, item: item, verdict: firstVerdict, latency: first.latency)
    }

    // MARK: - Recall: "Say it naturally" (spec §39, §80)

    private func runRecall(_ item: LearningItem) async throws {
        guard let prompt = item.promptEn else { return }
        try await cue(.sayInJapanese)
        emit(.line(ScriptLine(role: .instruction, japanese: "", english: prompt)))
        try await speak(prompt, .english)

        let replay: () async throws -> Void = { try await self.speak(prompt, .english) }
        let expected = item.keyTerms.flatMap(\.anyOf)
        guard let first = try await awaitAnswer(expecting: expected, announce: true, replay: replay) else { return }

        let evaluation = await evaluateRecall(first.transcript, item: item, prompt: prompt)
        await recordMistakes(evaluation.mistakes, itemID: item.id)
        let model = evaluation.naturalVersion.isEmpty ? item.japanese : evaluation.naturalVersion
        let needsRetry = try await deliverFeedback(evaluation, heard: first.transcript, model: model, item: item)

        if needsRetry {
            let retryReplay: () async throws -> Void = {
                try await self.sayJapanese(model, kana: "", english: item.english, role: .coach, rate: self.learner.difficulty.speechRate)
            }
            if let retry = try await awaitAnswer(expecting: expected, announce: false, replay: retryReplay) {
                if JapaneseText.bestSimilarity(retry.transcript, to: [model] + item.referenceResponses) >= 0.75 {
                    voice.feedback.play(.correct)
                    try await cue(.good)
                } else {
                    try await cue(.noProblem)
                }
            }
        }

        await updateKnowledge(item, .spokenRecall, verdict: evaluation.verdict, latency: first.latency)
        await updateKnowledge(item, .context, verdict: evaluation.verdict, latency: nil)
        if JapaneseText.bestSimilarity(first.transcript, to: item.referenceResponses) >= 0.75 {
            await updateKnowledge(item, .pronunciation, verdict: .natural, latency: nil)
        }
        recordResult(.recall, item: item, verdict: evaluation.verdict, latency: first.latency)
    }

    /// Local evaluation first; ask the AI only when the heuristic isn't sure (spec §40).
    private func evaluateRecall(_ transcript: String, item: LearningItem, prompt: String) async -> TurnEvaluation {
        let local = evaluator.evaluate(transcript, against: EvaluationTarget(item: item))
        guard !local.isConfident else { return TurnEvaluation(local: local, said: transcript) }
        emit(.activity(.thinking))
        let request = EvaluationRequest(mode: .recall, prompt: prompt, examples: item.referenceResponses,
                                        learnerUtterance: transcript, learnerLevel: learner.difficulty.level,
                                        politeness: item.politeness)
        do {
            let remote = try await ai.evaluateResponse(request)
            reportAIHealth()
            return remote
        } catch {
            return TurnEvaluation(local: local, said: transcript)
        }
    }

    /// Speaks feedback, communication first (spec §75). Returns true when the learner should try again.
    private func deliverFeedback(_ evaluation: TurnEvaluation, heard: String, model: String, item: LearningItem) async throws -> Bool {
        let rate = learner.difficulty.speechRate
        let explain = learner.difficulty.usesEnglishPrompts && !evaluation.feedbackEn.isEmpty
        switch evaluation.verdict {
        case .natural:
            voice.feedback.play(.correct)
            emit(.feedback(FeedbackNote(verdict: .natural, headline: "Natural", suggestion: model, heard: heard)))
            try await cue(.veryNatural)
            return false

        case .acceptable:
            voice.feedback.play(.correct)
            let differs = JapaneseText.similarity(heard, model) < 0.85
            emit(.feedback(FeedbackNote(verdict: .acceptable, headline: "Correct",
                                        detail: differs ? "A colleague might also say:" : "",
                                        suggestion: model, heard: heard)))
            try await cue(.good)
            if differs {
                try await cue(.moreNaturally)
                try await sayJapanese(model, kana: "", english: item.english, role: .coach, rate: rate)
            }
            return false

        case .understandable, .contextuallyInappropriate:
            voice.feedback.play(.tryAgain)
            emit(.feedback(FeedbackNote(verdict: evaluation.verdict, headline: "Meaning comes across",
                                        detail: evaluation.feedbackEn, suggestion: model, heard: heard)))
            try await cue(.meaningClear)
            if explain { try await speak(evaluation.feedbackEn, .english) }
            try await cue(.moreNaturally)
            try await sayJapanese(model, kana: "", english: item.english, role: .coach, rate: rate)
            try await cue(.repeatAfterMe)
            return true

        case .incorrect:
            voice.feedback.play(.tryAgain)
            emit(.feedback(FeedbackNote(verdict: .incorrect, headline: "Almost",
                                        detail: evaluation.feedbackEn, suggestion: model, heard: heard)))
            if explain { try await speak(evaluation.feedbackEn, .english) }
            try await cue(.modelAnswer)
            try await sayJapanese(model, kana: "", english: item.english, role: .coach, rate: rate)
            try await cue(.tryAgain)
            return true

        case .unclear, .noResponse:
            emit(.feedback(FeedbackNote(verdict: evaluation.verdict, headline: "Let's hear it together",
                                        suggestion: model, heard: heard)))
            try await cue(.noProblem)
            try await cue(.modelAnswer)
            try await sayJapanese(model, kana: "", english: item.english, role: .coach, rate: max(0.7, rate - 0.1))
            try await cue(.repeatAfterMe)
            return true
        }
    }

    // MARK: - Shadowing (spec §37)

    private func runShadowing(_ item: LearningItem) async throws {
        let references = [item.japanese, item.kana]
        let slow = 0.75
        let natural = learner.difficulty.level >= 5 ? 1.25 : 1.0
        let replaySlow: () async throws -> Void = {
            try await self.sayJapanese(item.japanese, kana: item.kana, english: item.english, role: .coach, rate: slow)
        }

        try await cue(.repeatAfterMe)
        try await cue(.slowly)
        try await replaySlow()
        guard var attempt = try await awaitAnswer(expecting: [item.japanese], announce: false, replay: replaySlow) else { return }
        if JapaneseText.bestSimilarity(attempt.transcript, to: references) < 0.8 {
            try await cue(.tryAgain)
            try await replaySlow()
            if let retry = try await awaitAnswer(expecting: [item.japanese], announce: false, replay: replaySlow) {
                attempt = retry
            }
        }

        try await cue(.naturalSpeed)
        let replayNatural: () async throws -> Void = {
            try await self.sayJapanese(item.japanese, kana: item.kana, english: item.english, role: .coach, rate: natural)
        }
        try await replayNatural()
        let lastAttempt = try await awaitAnswer(expecting: [item.japanese], announce: false, replay: replayNatural) ?? attempt
        let similarity = JapaneseText.bestSimilarity(lastAttempt.transcript, to: references)

        // Honest feedback: we can only say whether the words were recognised (spec §36).
        let verdict: ResponseVerdict
        if lastAttempt.transcript.isEmpty {
            verdict = .noResponse
            emit(.feedback(FeedbackNote(verdict: verdict, headline: "Let's try this one again another time", suggestion: item.japanese)))
        } else if similarity >= 0.8 {
            verdict = .natural
            voice.feedback.play(.correct)
            emit(.feedback(FeedbackNote(verdict: verdict, headline: "Clearly understood", suggestion: item.japanese, heard: lastAttempt.transcript)))
            try await cue(.clearlyUnderstood)
        } else {
            verdict = similarity >= 0.6 ? .understandable : .unclear
            let missed = JapaneseText.unrecognizedSegments(heard: lastAttempt.transcript, reference: item.japanese)
            let detail = missed.isEmpty ? "Some sounds weren't recognised clearly." : "Not recognised clearly: " + missed.joined(separator: "、")
            emit(.feedback(FeedbackNote(verdict: verdict, headline: "Keep practising this one", detail: detail,
                                        suggestion: item.japanese, heard: lastAttempt.transcript)))
            if learner.difficulty.usesEnglishPrompts { try await speak("Some words weren't recognised clearly. We'll come back to this one.", .english) }
        }
        await updateKnowledge(item, .pronunciation, verdict: verdict, latency: nil)
        recordResult(.shadowing, item: item, verdict: verdict, latency: lastAttempt.latency)
    }

    // MARK: - Conversation / role-play (spec §6–8, §27–28, §82)

    private func runConversation(scenarioID: String, maxTurns: Int) async throws {
        guard let scenario = library.scenario(id: scenarioID), !scenario.beats.isEmpty,
              let persona = library.persona(id: scenario.personaID) else { return }
        if !scenarioIDs.contains(scenario.id) { scenarioIDs.append(scenario.id) }
        let partnerRole = LineRole.partner(name: persona.nameJa)
        let partnerRate = learner.difficulty.speechRate * persona.speakingRate
        let recurring = await repository.recurringMistakes(limit: 5).map(\.type.rawValue)

        emit(.line(ScriptLine(role: .instruction, japanese: scenario.titleJa, english: scenario.situationEn)))
        if learner.difficulty.usesEnglishPrompts { try await speak(scenario.situationEn, .english) }

        var history: [DialogueTurn] = []
        var partnerLine: CoachLine?
        if scenario.roleReversal {
            try await cue(.startConversation)
            if learner.difficulty.usesEnglishPrompts { try await speak(scenario.beats[0].hintEn, .english) }
        } else {
            let opening = scenario.beats[0]
            let line = CoachLine(japanese: opening.line, kana: opening.kana, english: opening.english)
            partnerLine = line
            try await sayJapanese(line.japanese, kana: line.kana, english: line.english, role: partnerRole, rate: partnerRate)
            history.append(DialogueTurn(speaker: .partner, japanese: line.japanese, english: line.english))
        }

        var turnIndex = 0
        while turnIndex < maxTurns {
            let beat = scenario.beats[min(turnIndex, scenario.beats.count - 1)]
            let replay: () async throws -> Void = {
                if let line = partnerLine {
                    try await self.sayJapanese(line.japanese, kana: line.kana, english: line.english, role: partnerRole, rate: partnerRate)
                } else {
                    try await self.speak(beat.hintEn, .english)
                }
            }
            let expected = beat.keyTerms.flatMap(\.anyOf)
            guard var answer = try await awaitAnswer(expecting: expected, announce: turnIndex == 0, replay: replay) else { break }

            if answer.transcript.isEmpty {
                // Help once with an example, then let them try (spec §34: simplify when struggling).
                let example = (beat.exampleResponses.first ?? "").replacingOccurrences(of: "{name}", with: learner.name)
                try await cue(.noProblem)
                if learner.difficulty.usesEnglishPrompts { try await speak(beat.hintEn, .english) }
                if !example.isEmpty {
                    try await cue(.modelAnswer)
                    try await sayJapanese(example, kana: "", english: "", role: .coach, rate: max(0.7, learner.difficulty.speechRate - 0.1))
                }
                guard let retry = try await awaitAnswer(expecting: expected, announce: false, replay: replay),
                      !retry.transcript.isEmpty else {
                    recordResult(.conversation, item: nil, verdict: .noResponse, latency: nil)
                    break
                }
                answer = retry
            }

            conversationTurns += 1
            history.append(DialogueTurn(speaker: .learner, japanese: answer.transcript))
            let context = ConversationContext(
                scenarioID: scenario.id, scenarioTitle: scenario.title, situation: scenario.situationEn,
                persona: PersonaBrief(persona), learnerName: learner.name, learnerLevel: learner.difficulty.level,
                englishSupport: learner.difficulty.englishSupport, targetTerms: targetWords(for: scenario),
                recurringMistakeTypes: recurring, history: history, turnIndex: turnIndex, maxTurns: maxTurns
            )
            emit(.activity(.thinking))
            let response: TurnResponse
            do {
                response = try await ai.generateResponse(TurnRequest(context: context, learnerUtterance: answer.transcript,
                                                                     asrConfidence: answer.confidence))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                break
            }
            reportAIHealth()
            try Task.checkCancellation()

            await recordMistakes(response.evaluation.mistakes, itemID: nil)
            try await conversationFeedback(response.evaluation, heard: answer.transcript)
            recordResult(.conversation, item: nil, verdict: response.evaluation.verdict, latency: answer.latency)

            partnerLine = response.reply
            history.append(DialogueTurn(speaker: .partner, japanese: response.reply.japanese, english: response.reply.english))
            try await sayJapanese(response.reply.japanese, kana: response.reply.kana, english: response.reply.english,
                                  role: partnerRole, rate: partnerRate)
            turnIndex += 1
            if response.shouldEnd { break }
        }
        try await cue(.conversationEnd)
    }

    /// In conversation, keep the flow: only interrupt for real mistakes (spec §75).
    private func conversationFeedback(_ evaluation: TurnEvaluation, heard: String) async throws {
        let hasIssue = !evaluation.mistakes.isEmpty || evaluation.verdict == .incorrect || evaluation.verdict == .contextuallyInappropriate
        guard hasIssue else {
            if evaluation.verdict == .natural { voice.feedback.play(.correct) }
            if !evaluation.naturalVersion.isEmpty && evaluation.verdict != .natural {
                emit(.feedback(FeedbackNote(verdict: evaluation.verdict, headline: "Good — another way to say it",
                                            suggestion: evaluation.naturalVersion, heard: heard)))
            }
            return
        }
        emit(.feedback(FeedbackNote(verdict: evaluation.verdict, headline: evaluation.understood ? "Meaning comes across" : "Let's fix one thing",
                                    detail: evaluation.feedbackEn, suggestion: evaluation.naturalVersion, heard: heard)))
        if evaluation.understood { try await cue(.meaningClear) }
        if learner.difficulty.usesEnglishPrompts && !evaluation.feedbackEn.isEmpty {
            try await speak(evaluation.feedbackEn, .english)
        }
        if !evaluation.naturalVersion.isEmpty {
            try await cue(.moreNaturally)
            try await sayJapanese(evaluation.naturalVersion, kana: "", english: "", role: .coach, rate: learner.difficulty.speechRate)
        }
    }

    private func targetWords(for scenario: Scenario) -> [String] {
        scenario.targetTerms.compactMap { library.term(id: $0)?.japanese }
    }

    // MARK: - Turn-taking

    /// Hands the turn to the learner and handles spoken commands. Returns nil if the learner asked to skip.
    /// 「わかりません」 is returned as an empty answer so the exercise gives the model answer.
    private func awaitAnswer(expecting expected: [String], announce: Bool,
                             replay: () async throws -> Void) async throws -> ListenResult? {
        var shouldAnnounce = announce
        for _ in 0..<3 {
            let result = try await listen(expecting: expected, announce: shouldAnnounce)
            switch VoiceCommand.detect(in: result.transcript) {
            case .repeatPrompt?:
                try await replay()
                shouldAnnounce = false
            case .skip?:
                return nil
            case .pause?:
                pause()
                throw CancellationError()
            case .dontKnow?:
                return ListenResult(transcript: "", latency: result.latency, outcome: .noSpeech)
            case nil:
                return result
            }
        }
        return .silence
    }

    private func listen(expecting expected: [String], announce: Bool) async throws -> ListenResult {
        if announce { try await cue(.yourTurn) }
        try Task.checkCancellation()
        voice.feedback.play(.yourTurn)
        emit(.activity(.listening))
        let options = ListenOptions(startTimeout: learner.difficulty.responseWindow, endSilence: 1.4,
                                    maxDuration: 25, contextualStrings: expected)
        let result = await voice.recognizer.listen(options) { [weak self] partial in
            self?.emit(.partialTranscript(partial))
        }
        try Task.checkCancellation()
        secondsSpeaking += result.speakingDuration
        if !result.transcript.isEmpty {
            emit(.line(ScriptLine(role: .learner, japanese: result.transcript)))
        }
        emit(.activity(.thinking))
        return result
    }

    // MARK: - Speech output

    /// Speaks a coach cue in Japanese, with an English gloss the first time it's used while English support is high.
    private func cue(_ key: CueKey) async throws {
        let cue = library.cue(key)
        emit(.line(ScriptLine(role: .coach, japanese: cue.ja, kana: cue.kana, english: cue.en)))
        try await speak(cue.ja, .japanese, rate: learner.difficulty.speechRate)
        if learner.difficulty.usesEnglishGlosses && !glossedCues.contains(key) {
            glossedCues.insert(key)
            try await speak(cue.en, .english)
        }
    }

    /// `show: false` speaks without putting the text on screen (listening items are revealed after the attempt).
    private func sayJapanese(_ text: String, kana: String, english: String, role: LineRole, rate: Double, show: Bool = true) async throws {
        guard !text.isEmpty else { return }
        if show { emit(.line(ScriptLine(role: role, japanese: text, kana: kana, english: english))) }
        try await speak(text, .japanese, rate: rate)
    }

    private func speak(_ text: String, _ language: SpeechLanguage, rate: Double = 1.0) async throws {
        guard !text.isEmpty else { return }
        try Task.checkCancellation()
        emit(.activity(.speaking))
        let began = now()
        await voice.synthesizer.speak(SpeechRequest(text: text, language: language, rate: rate))
        if language == .japanese { secondsListening += now().timeIntervalSince(began) }
        try Task.checkCancellation()
    }

    // MARK: - Learning records

    private func updateKnowledge(_ item: LearningItem, _ dimension: SkillDimension, verdict: ResponseVerdict, latency: TimeInterval?) async {
        let date = now()
        let stored = await repository.knowledge(for: [item.id])
        let existing = stored[item.id] ?? KnowledgeState(itemID: item.id, introducedAt: date)
        let grade = ReviewGrade(verdict: verdict, latency: latency)
        let updated = scheduler.record(existing, dimension: dimension, grade: grade,
                                       latency: dimension == .spokenRecall ? latency : nil, at: date)
        await repository.save(updated)
    }

    private func recordMistakes(_ detected: [DetectedMistake], itemID: String?) async {
        for mistake in detected {
            let observation = MistakeObservation(type: mistake.type, itemID: itemID, said: mistake.said,
                                                 correction: mistake.correction, explanation: mistake.explanation, date: now())
            mistakes.append(observation)
            await repository.record(observation)
        }
    }

    private func recordResult(_ kind: ExerciseKind, item: LearningItem?, verdict: ResponseVerdict, latency: TimeInterval?) {
        results.append(ExerciseResult(kind: kind, itemID: item?.id, verdict: verdict, latency: latency, date: now()))
        guard let item else { return }
        if verdict == .natural || (verdict == .acceptable && (latency ?? 0) < 5) {
            wentWell.append(item.japanese)
        } else if !verdict.isSuccess {
            toPractise.append(item.japanese)
        }
    }

    private func reportAIHealth() {
        if let resilient = ai as? ResilientAIProvider {
            emit(.aiDegraded(resilient.lastFailure != nil))
        }
    }

    private func emit(_ event: SessionEvent) {
        onEvent?(event)
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
