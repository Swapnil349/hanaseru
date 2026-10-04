import Foundation
import LearningCore
import ConversationCore

/// The exercises, all in teach-before-test form.
extension SessionRunner {
    // MARK: - Say it (phrase items)

    /// A phrase never practised before is taught first (and comes back after the next exercise);
    /// a known phrase gets one turn at the level its history earns.
    func runRecall(_ item: LearningItem) async throws {
        let line = library.practiceLine(item: item)
        if let entry = await entryLevel(for: line) {
            try await runSayIt(line, level: entry, mode: .drill)
        } else {
            try await runIntroduce(line)
            queueRecall(line, level: .guided, needsGap: false)
        }
    }

    // MARK: - Listening ("Catch it")

    /// Topic preview in English, the sentence (hidden), one question, one answer — then the answer and
    /// the sentence are always revealed. Nothing is re-asked.
    func runListening(_ item: LearningItem) async throws {
        guard let check = item.listening else { return }
        let line = library.practiceLine(item: item)
        lastLineID = line.id
        let voiceGender = line.partner?.gender
        let topic = check.topicEn ?? ("Then I'll ask: " + check.questionEn)
        let stored = await repository.knowledge(for: [item.id])[item.id]
        let listeningStrength = stored?.state(.listening).strength ?? 0
        func question(choice: Bool) -> (ja: String, en: String) {
            choice ? (check.choiceQuestionJa ?? check.questionJa, check.choiceQuestionEn ?? check.questionEn)
                : (check.questionJa, check.questionEn)
        }
        var useChoice = listeningStrength < 0.4 && check.choiceQuestionJa != nil
        var asked = question(choice: useChoice)

        emit(.focus(FocusInfo(lineID: item.id, level: .model, cueEn: topic, english: "", japanese: "", kana: "",
                              visibleJapanese: "", heading: "LISTEN")))
        try await coach(.listenFor, ["topic": topic])
        try await partnerSays(item.japanese, gender: voiceGender, rate: 0.9, show: false)
        try await askListeningQuestion(asked, topic: topic, itemID: item.id)

        var expected = [check.modelAnswer]
        expected.append(contentsOf: check.answerTerms.flatMap(\.anyOf))
        var helpUsed = false
        var moreTimeUsed = false
        var skipped = false
        var timeout: TimeInterval = 6
        var transcript = ""
        listening: for _ in 0..<6 {
            var pending = takePendingCommand()
            var heard = ""
            if pending == nil {
                let result = try await listenOnce(timeout: timeout, endSilence: 1.4, contextual: expected,
                                                  cue: .yourTurn, nudgeAt: 0)
                pending = takePendingCommand()
                if pending == nil, let spoken = VoiceCommand.detect(in: result.transcript, expected: expected) {
                    pending = .voice(spoken)
                }
                heard = result.transcript
            }
            guard let command = pending else {
                transcript = heard
                break
            }
            timeout = 6
            switch command {
            case .voice(.pause):
                pause()
                throw CancellationError()
            case .voice(.skip):
                skipped = true
                break listening
            case .voice(.answer), .answerAndNext:
                break listening
            case .voice(.moreTime):
                if !moreTimeUsed {
                    moreTimeUsed = true
                    timeout = 14
                }
            case .voice(.repeatPrompt), .voice(.slower), .voice(.english), .voice(.hint):
                // One replay or hint; asking again after that gives the answer.
                guard !helpUsed else { break listening }
                helpUsed = true
                if command == .voice(.english) {
                    try await speak(asked.en, .english)
                } else if command == .voice(.hint) && !useChoice && check.choiceQuestionJa != nil {
                    // The easier either/or question.
                    useChoice = true
                    asked = question(choice: true)
                    try await askListeningQuestion(asked, topic: topic, itemID: item.id)
                } else {
                    try await partnerSays(item.japanese, gender: voiceGender, rate: command == .voice(.slower) ? 0.75 : 0.8,
                                          show: false)
                    try await speak(asked.ja, .japanese, rate: learner.difficulty.speechRate, voiceRole: .coachJapanese)
                }
            }
        }

        if skipped {
            emit(.reveal(RevealInfo(lineID: item.id, japanese: item.japanese, kana: item.kana, english: item.english,
                                    heard: "", outcome: .skipped)))
            results.append(ExerciseResult(kind: .listening, itemID: item.id, verdict: .noResponse, latency: nil,
                                          date: now(), lineID: item.id, level: nil, outcome: .skipped))
            return
        }

        let target = EvaluationTarget(listening: check)
        let correct = !transcript.isEmpty && evaluator.evaluate(transcript, against: target).verdict.isSuccess
        let answerEnglish = check.modelAnswerEn.isEmpty ? check.modelAnswer : check.modelAnswerEn
        let usedRepeat = helpUsed
        if correct {
            voice.feedback.play(.correct)
            try await coach(.thatsRight)
        } else {
            voice.feedback.play(.reveal)
            try await coach(.itWas, ["english": answerEnglish])
        }
        try await speak(check.modelAnswer, .japanese, rate: 0.9, voiceRole: .coachJapanese)

        // Always reveal the sentence and its meaning.
        emit(.reveal(RevealInfo(lineID: item.id, japanese: item.japanese, kana: item.kana, english: item.english,
                                heard: transcript, outcome: correct ? .clean : .modelNeeded)))
        emit(.feedback(FeedbackNote(verdict: correct ? .acceptable : .incorrect,
                                    headline: correct ? "You caught it" : "Here's what was said",
                                    detail: check.questionEn, suggestion: check.modelAnswer, heard: transcript)))
        try await partnerSays(item.japanese, kana: item.kana, english: item.english, gender: voiceGender, rate: 1.0)
        if listeningStrength < 0.4 || learner.difficulty.englishSupport >= 0.6 {
            try await speak(item.english, .english)
        }
        exposed.insert(line.id)

        let grade: ReviewGrade = correct ? (usedRepeat ? .hard : .good) : .again
        await updateKnowledge(id: item.id, .listening, grade: grade)
        if correct { await updateKnowledge(id: item.id, .recognition, grade: .good) }
        results.append(ExerciseResult(kind: .listening, itemID: item.id, verdict: correct ? .acceptable : .incorrect,
                                      latency: nil, date: now(), lineID: item.id, level: nil,
                                      outcome: correct ? (usedRepeat ? .hinted : .clean) : .modelNeeded))
    }

    /// Asks the listening question aloud and puts it on screen, so it can be answered with the phone in a
    /// pocket or by reading it.
    func askListeningQuestion(_ question: (ja: String, en: String), topic: String, itemID: String) async throws {
        let withEnglish = learner.difficulty.englishSupport >= 0.6
        emit(.line(ScriptLine(role: .coach, japanese: question.ja, english: question.en)))
        emit(.focus(FocusInfo(lineID: itemID, level: .model, cueEn: withEnglish ? question.en : topic, english: "",
                              japanese: question.ja, kana: "", visibleJapanese: question.ja, heading: "LISTEN")))
        try await speak(question.ja, .japanese, rate: learner.difficulty.speechRate, voiceRole: .coachJapanese)
        if withEnglish { try await speak(question.en, .english) }
    }

    // MARK: - Shadowing

    /// Say it with me: meaning, then the line slowly and at natural speed, echoing each. Never retried.
    func runShadowing(_ item: LearningItem) async throws {
        let line = library.practiceLine(item: item)
        lastLineID = line.id
        emit(.focus(focusInfo(line, level: .model)))
        try await coach(.sayWithMe)
        try await speak(line.english, .english, pauseAfter: 0.3)
        try await sayModel(line, rate: 0.85)
        _ = try await runEcho(line, window: 5, silentNote: false)
        try await sayModel(line, rate: learner.difficulty.level >= 5 ? 1.15 : 1.0, show: false)
        let echo = try await runEcho(line, window: 5)
        exposed.insert(line.id)

        let outcome: TurnOutcome
        if echo.heard {
            let similarity = JapaneseText.bestSimilarity(echo.transcript, to: [line.japanese, line.kana])
            let clarity: ReviewGrade = similarity >= 0.8 ? .good : (similarity >= 0.6 ? .hard : .again)
            await updateKnowledge(id: line.id, .pronunciation, grade: clarity)
            outcome = similarity >= 0.8 ? .clean : .partial
            if similarity >= 0.8 { try await coach(.clearlyUnderstood) }
        } else {
            outcome = .skipped
        }
        results.append(ExerciseResult(kind: .shadowing, itemID: item.id, verdict: outcome.legacyVerdict, latency: nil,
                                      date: now(), lineID: line.id, level: ScaffoldLevel.model.rawValue, outcome: outcome))
    }

    // MARK: - Scene (GABA-style: hear the whole screenplay with English, then perform it)

    func runConversation(scenarioID: String, maxTurns: Int) async throws {
        guard let scenario = library.scenario(id: scenarioID), let persona = library.persona(id: scenario.personaID) else { return }
        let lines = Array(library.lines(in: scenario, learnerName: learner.name).prefix(max(1, maxTurns)))
        guard !lines.isEmpty else { return }
        if !scenarioIDs.contains(scenario.id) { scenarioIDs.append(scenario.id) }

        // Brief.
        emit(.line(ScriptLine(role: .instruction, japanese: scenario.titleJa, english: scenario.situationEn)))
        try await coach(.sceneIntro, ["title": scenario.title])
        try await speakMixed(scenario.situationEn)
        try await coach(.sceneSteps)

        // Step 1 — screenplay: every line of both roles, with the learner's lines given in English and Japanese.
        emit(.step("Step 1 of 3 · Listen to the conversation"))
        try await coach(.listenFirst)
        for (index, line) in lines.enumerated() {
            if let partner = line.partner {
                try await partnerSays(partner, rate: 0.9)
                try await speak(partner.english, .english, pauseAfter: 0.3)
            }
            if index == 0 && scenario.roleReversal {
                try await coach(.youStart, ["english": line.english])
            } else {
                try await coach(.youLine, ["english": line.english])
            }
            try await sayModel(line, rate: 0.9, pauseAfter: 0.6)
            exposed.insert(line.id)
        }

        // Step 2 — practise each of the learner's lines: the partner's line, the meaning, the model, one echo.
        emit(.step("Step 2 of 3 · Practise your lines"))
        try await coach(.rehearseStart)
        for line in lines {
            emit(.focus(focusInfo(line, level: .model)))
            if let partner = line.partner { try await partnerSays(partner, rate: 0.9) }
            try await coach(.youSay, ["english": line.english])
            try await sayModel(line, rate: 0.85)
            _ = try await runEcho(line, window: 5, silentNote: false)
        }

        // Step 3 — perform: the partner speaks, a whispered English cue, the learner says the line.
        emit(.step("Step 3 of 3 · The real conversation"))
        if lines.first?.partner == nil {
            try await coach(.performYouStart)
        } else {
            try await coach(.performStart, ["name": persona.nameEn])
        }
        var previous: TurnOutcome?
        for (index, line) in lines.enumerated() {
            let rate = TurnTiming.partnerRate(level: .cued, profile: learner.difficulty, personaRate: persona.speakingRate)
            if let partner = line.partner {
                var prefix = ""
                if index > 0, previous?.communicated ?? false {
                    prefix = OfflineAIProvider.reaction(for: .acceptable, turn: index, nextLine: partner.japanese).ja
                }
                try await partnerSays(partner, rate: rate, prefix: prefix)
            }
            previous = try await runSayIt(line, level: .cued, mode: .perform, contextSpoken: true, kind: .conversation)
            conversationTurns += 1
        }
        if !scenario.closingLine.isEmpty {
            try await partnerSays(scenario.closingLine, kana: scenario.closingKana, english: scenario.closingEnglish,
                                  name: persona.nameJa, gender: persona.voiceGender,
                                  rate: TurnTiming.partnerRate(level: .cued, profile: learner.difficulty, personaRate: persona.speakingRate))
        }
        try await coach(.conversationEnd)
    }

    // MARK: - Help onboarding

    /// The hands-free help words, taught once: they're real meeting Japanese, so this is practice too.
    func runHelpOnboarding() async throws {
        try await coach(.helpIntro)
        try await coach(.chimeMeansTurn)
        voice.feedback.play(.yourTurn)
        try await coach(.ifMissed)
        let again = strategyLine(id: "h.mouichido", japanese: "もう一度お願いします。", kana: "もういちどおねがいします。",
                                 english: "Could you say that again, please?")
        try await sayModel(again, rate: 0.85)
        _ = try await runEcho(again, window: 4, silentNote: false)
        try await coach(.toHearSlowly)
        let slowly = strategyLine(id: "h.yukkuri", japanese: "ゆっくりお願いします。", kana: "ゆっくりおねがいします。",
                                  english: "Slowly, please.")
        try await sayModel(slowly, rate: 0.85)
        _ = try await runEcho(slowly, window: 4, silentNote: false)
        try await coach(.stuckHelp)
        try await coach(.alwaysAnswer)
        exposed.insert(again.id)
        exposed.insert(slowly.id)
    }

    /// A strategy phrase from the content, or a built-in version when the content doesn't have it.
    func strategyLine(id: String, japanese: String, kana: String, english: String) -> PracticeLine {
        if let item = library.item(id: id) { return library.practiceLine(item: item) }
        return PracticeLine(id: id, japanese: japanese, kana: kana, english: english,
                            chunks: [Chunk(ja: japanese, kana: kana)], level: 1, cueEn: "Say: " + english,
                            intentEn: "Say: " + english, references: [japanese, kana], keyTerms: [], mistakes: [],
                            politeness: .professional)
    }

    // MARK: - Closing

    /// 「今日の練習は終了です。」, then one line to keep — the one that needed the most help today —
    /// given in English and Japanese and echoed once. The session never ends on a failed attempt.
    func closing() async throws {
        try await coach(.sessionEnd)
        var keep = oneToKeep()
        if keep == nil, let id = plan.closingItemID, let item = library.item(id: id) {
            keep = library.practiceLine(item: item)
        }
        if let keep {
            closingLine = keep
            emit(.focus(focusInfo(keep, level: .model)))
            try await coach(.onePhrase, ["english": keep.english])
            try await sayModel(keep, rate: 0.85)
            _ = try await runEcho(keep, window: 5, silentNote: false)
        }
        try await coach(.wellDone)
        voice.feedback.play(.sessionComplete)
    }
}
