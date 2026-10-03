import Foundation
import LearningCore
import ConversationCore

/// The say-it turn: the only way the session asks the learner to produce Japanese.
///
/// cue → think (one timed nudge) → one attempt → the native model → one echo → move on.
/// The same cue is never asked twice; a missed line comes back later, one level easier.
extension SessionRunner {
    enum TurnMode: Equatable {
        /// Practice outside a performance: feedback after every turn.
        case drill
        /// A scene being performed: the coach stays quiet unless the model is needed.
        case perform
    }

    enum ListenAttempt {
        /// `slowed`: the learner asked for more time or held the turn with 「えーと」, so it can't be a fast answer.
        case speech(ListenResult, helped: Bool, slowed: Bool)
        case silent(helped: Bool)
        case answer(echo: Bool)
        case skipped
    }

    // MARK: - Say it

    /// Asks for a line at a level and handles everything that follows. Returns what happened.
    @discardableResult
    func runSayIt(_ line: PracticeLine, level: ScaffoldLevel, mode: TurnMode, contextSpoken: Bool = false,
                  kind: ExerciseKind = .recall) async throws -> TurnOutcome {
        // Teach before test: never ask for a line that hasn't been taught (this session or before).
        if level == .model {
            try await runIntroduce(line, contextSpoken: contextSpoken)
            return .skipped
        }
        if !exposed.contains(line.id) {
            let stored = await entryLevel(for: line)
            if stored == nil {
                ledgerViolations.append(line.id)
                try await runIntroduce(line, contextSpoken: contextSpoken)
                return .skipped
            }
        }

        appearances[line.id, default: 0] += 1
        lastLineID = line.id
        let timing = TurnTiming.make(level: level, chunkCount: line.chunks.count, profile: learner.difficulty)
        let partnerRate = TurnTiming.partnerRate(level: level, profile: learner.difficulty,
                                                 personaRate: line.partner?.speakingRate ?? 1)
        emit(.focus(focusInfo(line, level: level)))
        peekedThisTurn = false

        if !contextSpoken { try await speakContext(line, rate: partnerRate) }
        if mode == .drill, let partner = line.partner, !glossedPartnerLines.contains(line.id),
           learner.difficulty.englishSupport >= 0.3 || level <= .cued {
            glossedPartnerLines.insert(line.id)
            try await speak(partner.english, .english, pauseAfter: 0.3)
        }
        try await speakCue(line, level: level, mode: mode)

        let attempt = try await listenTurn(line, level: level, mode: mode, timing: timing, partnerRate: partnerRate)

        var transcript = ""
        var onset: TimeInterval?
        var local: LocalEvaluation?
        var remote: TurnEvaluation?
        let outcome: TurnOutcome
        var echoWindow: TimeInterval?
        var silent = false

        switch attempt {
        case .skipped:
            outcome = .skipped
        case .answer(let echo):
            outcome = .modelNeeded
            silent = true
            echoWindow = echo ? 5 : nil
        case .silent:
            outcome = .modelNeeded
            silent = true
            echoWindow = 5
        case .speech(let result, let helped, let slowed):
            transcript = result.transcript
            onset = result.latency
            if JapaneseText.isMostlyLatin(transcript) || !JapaneseText.containsJapanese(transcript) {
                outcome = .unclear
                echoWindow = 4
            } else {
                let judged = await judge(transcript, line: line, level: level, helped: helped, slowed: slowed, onset: onset)
                local = judged.local
                remote = judged.remote
                outcome = judged.outcome
                if !outcome.isClean && outcome != .hinted { echoWindow = 4 }
            }
        }

        if outcome != .unclear { unclearStreak = 0 }
        var detected: [DetectedMistake] = []
        if let remote {
            detected = remote.mistakes
        } else if let local {
            detected = local.matchedMistakes.map { pattern in
                DetectedMistake(type: pattern.type, said: transcript, correction: pattern.correction,
                                explanation: pattern.explanation)
            }
        }
        await recordMistakes(detected, itemID: line.itemID ?? line.id)

        do {
            try await deliver(outcome, line: line, level: level, mode: mode, transcript: transcript,
                              local: local, silent: silent, echoWindow: echoWindow, mistakes: detected, kind: kind)
        } catch {
            // Skipped or stopped during the feedback: the turn was already judged, so keep it.
            // Paused: nothing is kept, because the line is asked again on resume.
            if !isPaused {
                await record(line, level: level, outcome: outcome, transcript: transcript, onset: onset, kind: kind)
                if mode == .drill { requeue(line, level: level, outcome: outcome) }
            }
            throw error
        }
        await record(line, level: level, outcome: outcome, transcript: transcript, onset: onset, kind: kind)
        if mode == .drill { requeue(line, level: level, outcome: outcome) }
        return outcome
    }

    /// The partner's line, or the situation in English when there's no partner.
    func speakContext(_ line: PracticeLine, rate: Double) async throws {
        if let partner = line.partner {
            try await partnerSays(partner, rate: rate)
        } else if let situation = line.situationEn {
            emit(.line(ScriptLine(role: .instruction, japanese: "", english: situation)))
            try await speakMixed(situation)
        }
    }

    // MARK: - Listening with help

    /// One attempt with at most one nudge inside it, plus any help the learner asks for.
    func listenTurn(_ line: PracticeLine, level: ScaffoldLevel, mode: TurnMode, timing: TurnTiming,
                    partnerRate: Double) async throws -> ListenAttempt {
        let nudgeSpeech = nudge(for: line, level: level)
        var nudgeUsed = false
        var helped = false
        var replays = 0
        var moreTimeUsed = false
        var fillerHeld = false
        var slowed = false
        var timeout = nudgeSpeech.isEmpty ? timing.window : timing.nudgeAt
        var cue: HapticCue? = .yourTurn

        func freshWindow() -> TimeInterval {
            if nudgeUsed { return timing.afterNudge }
            return nudgeSpeech.isEmpty ? timing.window : timing.nudgeAt
        }

        for _ in 0..<12 {
            var command = takePendingCommand()
            var heard: ListenResult?
            if command == nil {
                let result = try await listenOnce(timeout: timeout, endSilence: timing.endSilence,
                                                  contextual: line.contextualStrings, cue: cue,
                                                  nudgeAt: (nudgeSpeech.isEmpty || nudgeUsed) ? 0 : timeout)
                command = takePendingCommand()
                if command == nil, let spoken = VoiceCommand.detect(in: result.transcript, expected: line.references) {
                    command = .voice(spoken)
                }
                heard = result
            }

            if let command {
                switch command {
                case .answerAndNext:
                    return .answer(echo: false)
                case .voice(let voiceCommand):
                    switch voiceCommand {
                    case .repeatPrompt:
                        replays += 1
                        if replays >= 3 { return .answer(echo: true) }
                        try await replayPrompt(line, level: level, mode: mode, rate: partnerRate)
                    case .slower:
                        try await replayPrompt(line, level: level, mode: mode, rate: 0.75)
                    case .english:
                        helped = true
                        if let partner = line.partner { try await speak(partner.english, .english, pauseAfter: 0.3) }
                        try await speakEnglishCue(line, volume: 1)
                        if level <= .cued {
                            try await speak(guidedStart(line).spoken, .japanese, rate: 0.85, voiceRole: .coachJapanese)
                        }
                    case .hint:
                        guard !nudgeUsed, !nudgeSpeech.isEmpty else { return .answer(echo: true) }
                        try await speakAll(nudgeSpeech)
                        nudgeUsed = true
                        helped = true
                        timeout = timing.afterNudge
                        cue = .nudge
                        continue
                    case .answer:
                        return .answer(echo: true)
                    case .moreTime:
                        slowed = true
                        if !moreTimeUsed {
                            moreTimeUsed = true
                            if !takeYourTimeSaid {
                                takeYourTimeSaid = true
                                try await coach(.takeYourTime)
                            }
                            timeout += 8
                        }
                        cue = nil
                        continue
                    case .skip:
                        return .skipped
                    case .pause:
                        pause()
                        throw CancellationError()
                    }
                }
                timeout = freshWindow()
                cue = .yourTurn
                continue
            }

            guard let result = heard else { continue }
            if result.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !nudgeUsed && !nudgeSpeech.isEmpty {
                    try await speakAll(nudgeSpeech)
                    nudgeUsed = true
                    helped = true
                    timeout = timing.afterNudge
                    cue = .nudge
                    continue
                }
                return .silent(helped: helped)
            }
            if !fillerHeld && JapaneseText.isFillerOnly(result.transcript)
                && JapaneseText.bestSimilarity(result.transcript, to: line.references) < 0.8 {
                // 「えーと」 holds the turn: a little more time, and no penalty.
                fillerHeld = true
                slowed = true
                timeout = 4
                cue = nil
                continue
            }
            return .speech(result, helped: helped || peekedThisTurn, slowed: slowed)
        }
        return .silent(helped: helped)
    }

    /// Replays the partner line (or situation) and the cue.
    func replayPrompt(_ line: PracticeLine, level: ScaffoldLevel, mode: TurnMode, rate: Double) async throws {
        try await speakContext(line, rate: rate)
        try await speakCue(line, level: level, mode: mode)
    }

    /// One microphone window. `cue` is the chime that hands over the turn.
    func listenOnce(timeout: TimeInterval, endSilence: TimeInterval, contextual: [String], cue: HapticCue?,
                    nudgeAt: TimeInterval) async throws -> ListenResult {
        try Task.checkCancellation()
        if let cue { voice.feedback.play(cue) }
        emit(.activity(.listening))
        emit(.turnWindow(seconds: timeout, nudgeAt: nudgeAt))
        isListening = true
        let options = ListenOptions(startTimeout: timeout, endSilence: endSilence, maxDuration: 15,
                                    contextualStrings: Array(contextual.prefix(100)))
        let result = await voice.recognizer.listen(options) { [weak self] partial in
            self?.emit(.partialTranscript(partial))
        }
        isListening = false
        try Task.checkCancellation()
        secondsSpeaking += result.speakingDuration
        if !result.transcript.isEmpty {
            emit(.line(ScriptLine(role: .learner, japanese: result.transcript)))
        }
        emit(.activity(.thinking))
        return result
    }

    // MARK: - Judging

    /// Local evaluation first; the AI coach gets 2.5 s for a second opinion when the heuristic isn't sure.
    /// Offline there is no second opinion (the offline engine is the same heuristic), so partial credit applies.
    func judge(_ transcript: String, line: PracticeLine, level: ScaffoldLevel, helped: Bool, slowed: Bool,
               onset: TimeInterval?) async -> (outcome: TurnOutcome, local: LocalEvaluation, remote: TurnEvaluation?) {
        let local = evaluator.evaluateBest(transcript, against: line.evaluationTarget)
        var verdict = local.verdict
        var remote: TurnEvaluation?
        if !local.isConfident && verdict != .noResponse && verdict != .unclear && !(ai is OfflineAIProvider) {
            emit(.activity(.thinking))
            let request = EvaluationRequest(mode: .recall, prompt: line.cueEn, examples: line.references,
                                            learnerUtterance: transcript, learnerLevel: learner.difficulty.level,
                                            politeness: line.politeness)
            let provider = ai
            remote = try? await withTimeout(2.5) { try await provider.evaluateResponse(request) }
            // When the coach was unreachable the answer came from the offline engine: keep the local verdict.
            if let resilient = ai as? ResilientAIProvider, resilient.lastFailure != nil { remote = nil }
            reportAIHealth()
            if let remote { verdict = remote.verdict }
        }

        let outcome: TurnOutcome
        switch verdict {
        case .natural, .acceptable:
            if helped {
                outcome = .hinted
            } else if verdict == .natural, !slowed, let onset, onset < TurnTiming.fastGate(level) {
                outcome = .cleanFast
            } else {
                outcome = .clean
            }
        case .understandable:
            outcome = .partial
        case .contextuallyInappropriate:
            outcome = .register
        case .incorrect:
            if !local.matchedMistakes.isEmpty {
                outcome = .modelNeeded
            } else if remote == nil && (local.similarity >= 0.4 || !local.matchedChunks.isEmpty) {
                // Unsure and offline: give credit for what was there.
                outcome = .partial
            } else {
                outcome = .modelNeeded
            }
        case .unclear:
            outcome = .unclear
        case .noResponse:
            outcome = .modelNeeded
        }
        return (outcome, local, remote)
    }

    // MARK: - Feedback

    /// Speaks what follows a turn. Communication first: no failure sounds, never "wrong", never "try again".
    func deliver(_ outcome: TurnOutcome, line: PracticeLine, level: ScaffoldLevel, mode: TurnMode, transcript: String,
                 local: LocalEvaluation?, silent: Bool, echoWindow: TimeInterval?, mistakes: [DetectedMistake],
                 kind: ExerciseKind) async throws {
        let matched = local?.matchedChunks.map(\.ja) ?? []
        let missing = local?.missingChunks.map(\.ja) ?? []
        // The screen gets the full explanation; the voice only a note written to be spoken (Japanese in 「」).
        var note = ""
        var spokenNote = ""
        if let mistake = mistakes.first {
            let authored = line.mistakes.first(where: { $0.correction == mistake.correction })
            note = mistake.explanation
            if let spoken = authored?.spokenEn, !spoken.isEmpty {
                spokenNote = spoken
            } else if JapaneseText.isSpeakableInstruction(mistake.explanation) {
                spokenNote = mistake.explanation
            }
        }
        emit(.reveal(RevealInfo(lineID: line.id, japanese: line.japanese, kana: line.kana, english: line.english,
                                heard: transcript, outcome: outcome, matchedChunks: matched, missingChunks: missing,
                                note: note)))
        emit(.feedback(FeedbackNote(verdict: outcome.legacyVerdict, headline: headline(outcome, matched: matched),
                                    detail: note, suggestion: line.japanese, heard: transcript)))

        if mode == .perform {
            switch outcome {
            case .clean, .cleanFast, .hinted:
                voice.feedback.play(.correct)
            case .partial, .register, .skipped:
                break
            case .modelNeeded, .unclear:
                voice.feedback.play(.reveal)
                try await coach(.youCouldSay)
                try await sayModel(line, rate: 0.85)
                if outcome == .modelNeeded && echoWindow == nil { break }
                _ = try await runEcho(line, window: 4)
            }
            return
        }

        switch outcome {
        case .cleanFast, .clean:
            voice.feedback.play(.correct)
            cleanSincePraise += 1
            if level <= .cued {
                try await sayModel(line, rate: 1.0)
            } else if (local?.similarity ?? 1) < 0.85 {
                try await coach(.alsoNatural)
                try await sayModel(line, rate: 1.0)
            }
            if cleanSincePraise >= 4 {
                cleanSincePraise = 0
                try await coach(.good)
            }
        case .hinted:
            voice.feedback.play(.correct)
            try await sayModel(line, rate: 1.0)
        case .partial:
            if let chunk = matched.last {
                try await coach(.close)
                try await speak(chunk, .japanese, rate: 0.9, voiceRole: .coachJapanese, pauseAfter: 0.1)
                try await coach(.wasRight)
            } else {
                try await coach(.naturalVersion)
            }
            try await sayModel(line, rate: 0.9)
            _ = try await runEcho(line, window: echoWindow ?? 4)
        case .register:
            let name = line.partner?.nameEn ?? ""
            try await coach(.morePolite, ["name": name.isEmpty ? "a senior colleague" : name])
            try await sayModel(line, rate: 0.9)
            _ = try await runEcho(line, window: echoWindow ?? 4)
        case .modelNeeded:
            voice.feedback.play(.reveal)
            if silent {
                try await coach(noProblemSaid ? .hereItIs : .noProblemHere)
                noProblemSaid = true
            } else {
                if !spokenNote.isEmpty && learner.difficulty.englishSupport >= 0.4 {
                    try await speakMixed(spokenNote)
                }
                try await coach(.hereIsHow)
            }
            try await sayModel(line, rate: 0.85, pauseAfter: 0.3)
            try await speak(line.english, .english)
            if let window = echoWindow { _ = try await runEcho(line, window: window) }
        case .unclear:
            unclearStreak += 1
            try await coach(.didntCatch)
            try await sayModel(line, rate: 0.85)
            _ = try await runEcho(line, window: echoWindow ?? 4)
            if unclearStreak >= 3 && !micCheckDone {
                micCheckDone = true
                try await coach(.micCheck)
            }
        case .skipped:
            break
        }
    }

    func headline(_ outcome: TurnOutcome, matched: [String]) -> String {
        switch outcome {
        case .cleanFast, .clean: "Nice"
        case .hinted: "Nice — with a hint"
        case .partial: matched.last.map { "Close — 「\($0)」 was right" } ?? "Close"
        case .register: "Clear meaning — more polite"
        case .modelNeeded: "Here's how to say it"
        case .unclear: "Here it is"
        case .skipped: "Skipped"
        }
    }

    // MARK: - Teaching

    /// S0: the line is taught — English meaning, then the Japanese twice (slow, then natural) with an echo
    /// after each. Nothing is asked for here. The line comes back for recall later in the session.
    func runIntroduce(_ line: PracticeLine, contextSpoken: Bool = false) async throws {
        lastLineID = line.id
        emit(.focus(focusInfo(line, level: .model)))
        if !contextSpoken {
            if let partner = line.partner {
                try await partnerSays(partner, rate: 0.85)
                try await speak(partner.english, .english, pauseAfter: 0.3)
                glossedPartnerLines.insert(line.id)
            } else if let situation = line.situationEn {
                emit(.line(ScriptLine(role: .instruction, japanese: "", english: situation)))
                try await speakMixed(situation)
            }
        }
        try await coach(.youSay, ["english": line.english])
        try await sayModel(line, rate: 0.85)
        let firstEcho = try await runEcho(line, window: 5, silentNote: false)
        try await sayModel(line, rate: 1.0, show: false)
        let secondEcho = try await runEcho(line, window: 5, silentNote: false)
        exposed.insert(line.id)
        introducedToday.insert(line.id)

        let stored = await entryLevel(for: line)
        if stored == nil, let note = line.noteEn, learner.difficulty.englishSupport >= 0.5 {
            try await speakMixed(note)
        }
        if !firstEcho.heard && !secondEcho.heard && !echoLaterSaid {
            echoLaterSaid = true
            try await coach(.echoLater)
        }
    }

    /// The learner repeats the model once. Never failed, never retried.
    func runEcho(_ line: PracticeLine, window: TimeInterval, silentNote: Bool = true) async throws -> (good: Bool, heard: Bool, transcript: String) {
        var replayed = false
        while true {
            let result = try await listenOnce(timeout: window, endSilence: 1.0, contextual: [line.japanese, line.kana],
                                              cue: .yourTurn, nudgeAt: 0)
            var command = takePendingCommand()
            if command == nil, let spoken = VoiceCommand.detect(in: result.transcript, expected: line.references) {
                command = PendingCommand.voice(spoken)
            }
            if let command {
                switch command {
                case .voice(.repeatPrompt) where !replayed, .voice(.slower) where !replayed:
                    replayed = true
                    try await sayModel(line, rate: command == .voice(.slower) ? 0.75 : 0.85, show: false)
                    continue
                case .voice(.pause):
                    pause()
                    throw CancellationError()
                default:
                    return (false, false, "")
                }
            }
            let transcript = result.transcript
            guard !JapaneseText.normalize(transcript).isEmpty else {
                if silentNote && !echoLaterSaid {
                    echoLaterSaid = true
                    try await coach(.echoLater)
                }
                return (false, false, "")
            }
            let good = evaluator.echoIsGood(transcript, model: line.japanese, kana: line.kana, keyTerms: line.keyTerms)
            if good { voice.feedback.play(.correct) }
            return (good, true, transcript)
        }
    }

    // MARK: - Coming back later

    /// Missed lines come back once, later, one level easier; new lines climb S0 → S1 → S2 (spec §4.3).
    func requeue(_ line: PracticeLine, level: ScaffoldLevel, outcome: TurnOutcome) {
        guard (appearances[line.id] ?? 0) < 4 else { return }
        switch outcome {
        case .clean, .cleanFast:
            if introducedToday.contains(line.id) && level < .cued {
                queueRecall(line, level: level.harder, needsGap: true)
            }
        case .hinted, .partial, .register, .unclear, .skipped:
            guard !requeuedOnce.contains(line.id) else { return }
            requeuedOnce.insert(line.id)
            queueRecall(line, level: level, needsGap: true)
        case .modelNeeded:
            guard !requeuedOnce.contains(line.id) else { return }
            requeuedOnce.insert(line.id)
            queueRecall(line, level: level.easier, needsGap: true)
        }
    }

    /// `needsGap: false` only for the first guided try of a line just taught, which may follow its teaching.
    func queueRecall(_ line: PracticeLine, level: ScaffoldLevel, needsGap: Bool) {
        pendingRecalls.append(PendingRecall(line: line, level: level, queuedDuring: currentExerciseIndex, needsGap: needsGap))
    }

    /// Runs the next line that is due to come back, if any. Between exercises, only lines queued before the
    /// exercise that just ended are due (`queuedBefore`), so something else always comes in between.
    @discardableResult
    func runOnePendingRecall(queuedBefore exerciseIndex: Int? = nil) async throws -> Bool {
        let isDue: (PendingRecall) -> Bool = { recall in
            if let exerciseIndex, recall.queuedDuring >= exerciseIndex { return false }
            return !(recall.needsGap && recall.line.id == self.lastLineID)
        }
        guard let position = pendingRecalls.firstIndex(where: isDue) else { return false }
        let next = pendingRecalls.remove(at: position)
        let previousLine = lastLineID
        do {
            if next.level == .model {
                try await runIntroduce(next.line)
                if (appearances[next.line.id] ?? 0) < 4 {
                    queueRecall(next.line, level: .guided, needsGap: true)
                }
            } else {
                try await runSayIt(next.line, level: next.level, mode: .drill)
            }
        } catch {
            // Paused: it plays again after resuming. Skipped or stopped: it doesn't come back.
            if isPaused {
                pendingRecalls.insert(next, at: 0)
                lastLineID = previousLine
            }
            throw error
        }
        return true
    }

    // MARK: - Records

    func entryLevel(for line: PracticeLine) async -> ScaffoldLevel? {
        let stored = await repository.knowledge(for: [line.id])
        return ScaffoldLevel.entry(from: stored[line.id])
    }

    func record(_ line: PracticeLine, level: ScaffoldLevel, outcome: TurnOutcome, transcript: String,
                onset: TimeInterval?, kind: ExerciseKind) async {
        let date = now()
        if let grade = ReviewGrade(outcome: outcome, level: level, onset: onset) {
            await updateKnowledge(id: line.id, .spokenRecall, grade: grade, latency: onset)
            if level >= .intent { await updateKnowledge(id: line.id, .context, grade: grade) }
            if JapaneseText.containsJapanese(transcript) {
                let similarity = JapaneseText.bestSimilarity(transcript, to: line.references + [line.kana])
                let clarity: ReviewGrade = similarity >= 0.8 ? .good : (similarity >= 0.6 ? .hard : .again)
                await updateKnowledge(id: line.id, .pronunciation, grade: clarity)
            }
        }
        results.append(ExerciseResult(kind: kind, itemID: line.itemID ?? line.id, verdict: outcome.legacyVerdict,
                                      latency: onset, date: date, lineID: line.id, level: level.rawValue, outcome: outcome))
        if outcome.isGraded {
            let previous = worstOutcomes[line.id]
            if previous == nil || outcome.severity < previous!.severity {
                worstOutcomes[line.id] = outcome
                worstLines[line.id] = line
            }
        }
        switch outcome {
        case .cleanFast, .clean: wentWell.append(line.japanese)
        case .modelNeeded, .partial, .register: toPractise.append(line.japanese)
        default: break
        }
    }

    func updateKnowledge(id: String, _ dimension: SkillDimension, grade: ReviewGrade, latency: TimeInterval? = nil) async {
        let date = now()
        let stored = await repository.knowledge(for: [id])
        let existing = stored[id] ?? KnowledgeState(itemID: id, introducedAt: date)
        let updated = scheduler.record(existing, dimension: dimension, grade: grade,
                                       latency: dimension == .spokenRecall ? latency : nil, at: date)
        await repository.save(updated)
    }

    func recordMistakes(_ detected: [DetectedMistake], itemID: String?) async {
        for mistake in detected {
            let observation = MistakeObservation(type: mistake.type, itemID: itemID, said: mistake.said,
                                                 correction: mistake.correction, explanation: mistake.explanation, date: now())
            mistakes.append(observation)
            await repository.record(observation)
        }
    }

    /// The line with the worst outcome today — said once more at the end (spec §3.9 "one to keep").
    func oneToKeep() -> PracticeLine? {
        let ranked = worstOutcomes.sorted { a, b in
            if a.value.severity != b.value.severity { return a.value.severity < b.value.severity }
            return a.key < b.key
        }
        guard let worst = ranked.first, worst.value.severity <= TurnOutcome.hinted.severity else { return nil }
        return worstLines[worst.key]
    }
}
