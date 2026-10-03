import Foundation
import LearningCore

/// Speaking: the coach's instructions, Japanese models and the partner's lines.
extension SessionRunner {
    /// Phrases always spoken in Japanese (session rituals and short reactions), whatever the coach language.
    static let ritualCues: Set<CueKey> = [
        .sessionStartWork, .sessionStartEveryday, .sessionStartGeneral, .sessionEnd, .wellDone,
        .conversationEnd, .good, .thatsRight, .takeYourTime, .clearlyUnderstood,
    ]

    /// Speaks text and returns when finished (or when the session is paused/stopped).
    func speak(_ text: String, _ language: SpeechLanguage, rate: Double = 1.0, voiceRole: VoiceRole? = nil,
               volume: Double = 1, pauseAfter: TimeInterval = 0.15) async throws {
        let spoken = language == .english ? JapaneseText.speakableEnglish(text) : text
        guard !spoken.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        try Task.checkCancellation()
        emit(.activity(.speaking))
        let began = now()
        await voice.synthesizer.speak(SpeechRequest(text: spoken, language: language, rate: rate, pauseAfter: pauseAfter,
                                                    voice: voiceRole, volume: volume))
        if language == .japanese { secondsListening += now().timeIntervalSince(began) }
        try Task.checkCancellation()
    }

    /// Speaks an English instruction in which text inside 「」 is spoken by the Japanese voice,
    /// e.g. "Stuck? Say 「ヒント」 for a hint." English and Japanese are never mixed in one utterance.
    func speakMixed(_ text: String, volume: Double = 1) async throws {
        for segment in JapaneseText.bilingualSegments(text) {
            if segment.isJapanese {
                try await speak(segment.text, .japanese, rate: 0.9, volume: volume, pauseAfter: 0.1)
            } else {
                try await speak(segment.text, .english, volume: volume, pauseAfter: 0.1)
            }
        }
    }

    /// A coach instruction from cues.json in the coach's language. The English *content* of a line being
    /// taught ({english}) is spoken in every mode, because the learner needs the meaning to learn the line.
    func coach(_ key: CueKey, _ values: [String: String] = [:], volume: Double = 1) async throws {
        let cue = library.cue(key)
        let english = library.fill(cue.en, values)
        emit(.line(ScriptLine(role: .coach, japanese: cue.ja, kana: cue.kana, english: english)))
        if Self.ritualCues.contains(key) {
            // Everyday Japanese worth hearing every time; glossed in English the first time only.
            try await speak(cue.ja, .japanese, rate: learner.difficulty.speechRate, voiceRole: .coachJapanese, volume: volume)
            if learner.difficulty.usesEnglishGlosses && !glossedCues.contains(key) {
                glossedCues.insert(key)
                try await speakMixed(english, volume: volume)
            }
            return
        }
        let content = cue.en.contains("{english}") ? values["english"] : nil
        switch learner.difficulty.coachLanguage {
        case .english:
            try await speakMixed(english, volume: volume)
        case .bilingual:
            try await speak(cue.ja, .japanese, rate: learner.difficulty.speechRate, volume: volume)
            if !glossedCues.contains(key) {
                glossedCues.insert(key)
                try await speakMixed(english, volume: volume)
            } else if let content {
                try await speak(content, .english, volume: volume)
            }
        case .japanese:
            try await speak(cue.ja, .japanese, rate: learner.difficulty.speechRate, volume: volume)
            if let content { try await speak(content, .english, volume: volume) }
        }
    }

    /// The model of one of the learner's own lines, in the coach's Japanese voice.
    func sayModel(_ line: PracticeLine, rate: Double, show: Bool = true, pauseAfter: TimeInterval = 0.2) async throws {
        if show { emit(.line(ScriptLine(role: .coach, japanese: line.japanese, kana: line.kana, english: line.english))) }
        try await speak(line.japanese, .japanese, rate: rate, voiceRole: .coachJapanese, pauseAfter: pauseAfter)
    }

    /// A line from the role-play partner, in the partner's voice.
    func partnerSays(_ japanese: String, kana: String = "", english: String = "", name: String = "",
                     gender: VoiceGender?, rate: Double, show: Bool = true) async throws {
        if show { emit(.line(ScriptLine(role: .partner(name: name), japanese: japanese, kana: kana, english: english))) }
        try await speak(japanese, .japanese, rate: rate, voiceRole: .partner(gender), pauseAfter: 0.4)
    }

    /// The partner line before one of the learner's lines.
    func partnerSays(_ partner: PracticePartner, rate: Double, prefix: String = "") async throws {
        try await partnerSays(prefix + partner.japanese, kana: partner.kana, english: partner.english,
                              name: partner.nameJa, gender: partner.gender, rate: rate)
    }

    /// The cue that asks for a line at its level. Cues are whispered (quieter) during a performance.
    func speakCue(_ line: PracticeLine, level: ScaffoldLevel, mode: TurnMode) async throws {
        let volume = mode == .perform ? 0.6 : 1.0
        switch level {
        case .model:
            break
        case .guided:
            try await speakEnglishCue(line, volume: volume)
            try await coach(.itStarts, volume: volume)
            try await speak(guidedStart(line).spoken, .japanese, rate: 0.85, voiceRole: .coachJapanese, volume: volume)
        case .cued:
            try await speakEnglishCue(line, volume: volume)
        case .intent:
            emit(.line(ScriptLine(role: .instruction, japanese: "", english: line.intentEn)))
            try await speakMixed(line.intentEn, volume: 0.6)
        case .free, .fluent:
            break
        }
    }

    /// "Say: <meaning>" — the line's own cue in English mode, or the Japanese instruction plus the meaning.
    func speakEnglishCue(_ line: PracticeLine, volume: Double) async throws {
        emit(.line(ScriptLine(role: .instruction, japanese: "", english: line.cueEn)))
        if learner.difficulty.coachLanguage == .english {
            try await speakMixed(line.cueEn, volume: volume)
        } else {
            try await coach(line.isQuestion ? .ask : .say, ["english": line.english], volume: volume)
        }
    }

    /// Answer words that give nothing away on their own: a hint never stops at 「はい」 or 「いいえ」.
    static let leadWords: Set<String> = ["はい", "いいえ", "いえ", "いえいえ", "ええ", "うん"]

    /// The line's chunks, with a leading はい／いいえ split off so hints start from what follows it.
    func hintParts(_ line: PracticeLine) -> (lead: Chunk?, rest: [Chunk]) {
        guard line.chunks.count >= 2, let first = line.chunks.first,
              Self.leadWords.contains(JapaneseText.normalize(first.kana.isEmpty ? first.ja : first.kana)) else {
            return (nil, line.chunks)
        }
        return (first, Array(line.chunks.dropFirst()))
    }

    /// What S1 gives away: the first chunk (after any はい／いいえ), or the first two morae of a short line.
    func guidedStart(_ line: PracticeLine) -> (spoken: String, shown: String, shownKana: String) {
        let (lead, rest) = hintParts(line)
        let leadJa = lead?.ja ?? ""
        let leadKana = lead?.kana ?? ""
        if rest.count >= 3, let first = rest.first {
            return (leadJa + first.ja, leadJa + first.ja, leadKana + first.kana)
        }
        let source = rest.first?.kana ?? line.kana
        let morae = JapaneseText.firstMorae(source.isEmpty ? line.japanese : source, count: 2)
        return (leadJa + morae + "…", leadKana + morae, leadKana + morae)
    }

    /// One more step of information, given halfway through the think time (spec §3.1).
    func nudge(for line: PracticeLine, level: ScaffoldLevel) -> [SpeechRequest] {
        switch level {
        case .model:
            return []
        case .guided:
            // S1 already gave the start, so the nudge gives the next piece.
            let (lead, rest) = hintParts(line)
            let text: String
            if rest.count >= 3 {
                text = rest[1].ja
            } else if rest.count == 2 {
                text = (lead?.ja ?? "") + rest[0].ja
            } else {
                let kana = rest.first?.kana ?? line.kana
                let morae = max(3, (JapaneseText.moraCount(kana) + 1) / 2)
                text = (lead?.ja ?? "") + JapaneseText.firstMorae(kana, count: morae)
            }
            return [SpeechRequest(text: text + "…", language: .japanese, rate: 0.85, voice: .coachJapanese)]
        case .cued:
            let text = guidedStart(line).spoken
            return [SpeechRequest(text: text.hasSuffix("…") ? text : text + "…", language: .japanese, rate: 0.85, voice: .coachJapanese)]
        case .intent:
            return [SpeechRequest(text: "Like: " + line.english, language: .english)]
        case .free, .fluent:
            if let choice = line.choiceVariant {
                return [SpeechRequest(text: choice.japanese, language: .japanese, rate: 0.9, voice: .partner(line.partner?.gender))]
            }
            return [SpeechRequest(text: line.intentEn, language: .english, volume: 0.6)]
        }
    }

    func speakAll(_ requests: [SpeechRequest]) async throws {
        for request in requests {
            if request.language == .english {
                try await speakMixed(request.text, volume: request.volume)
            } else {
                try await speak(request.text, request.language, rate: request.rate, voiceRole: request.voice,
                                volume: request.volume, pauseAfter: request.pauseAfter)
            }
        }
    }

    /// What the screen shows while the learner thinks.
    func focusInfo(_ line: PracticeLine, level: ScaffoldLevel) -> FocusInfo {
        let cue: String = switch level {
        case .model, .guided, .cued: line.cueEn
        case .intent: line.intentEn
        case .free, .fluent: "Your move: " + line.intentEn
        }
        var visible = ""
        var placeholder = ""
        switch level {
        case .model:
            visible = line.japanese
        case .guided:
            let start = guidedStart(line)
            visible = start.shown
            let hidden = max(1, JapaneseText.moraCount(line.kana) - JapaneseText.moraCount(start.shownKana))
            placeholder = String(repeating: "○", count: min(hidden, 12))
        default:
            break
        }
        return FocusInfo(lineID: line.id, level: level, cueEn: cue, english: line.english, japanese: line.japanese,
                         kana: line.kana, visibleJapanese: visible, hiddenPlaceholder: placeholder,
                         partnerJapanese: line.partner?.japanese ?? "", partnerEnglish: line.partner?.english ?? "",
                         partnerName: line.partner?.nameEn ?? "")
    }
}
