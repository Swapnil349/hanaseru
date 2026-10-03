import Foundation

/// Text utilities for comparing what the learner said (as transcribed) with reference Japanese.
///
/// Speech recognisers are inconsistent about punctuation, spacing, full-width characters and
/// katakana vs hiragana, so comparisons always go through `normalize`.
public enum JapaneseText {
    static let ignorable: Set<Unicode.Scalar> = Set("、。，．？！?!,.・「」『』（）()〜~…:：;；\"' \u{3000}\n\t".unicodeScalars)

    /// Lower-cases, folds full-width ASCII to ASCII, folds katakana to hiragana and strips punctuation and spaces.
    /// The long-vowel mark ー is kept because it changes meaning.
    public static func normalize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            var value = scalar.value
            if (0xFF01...0xFF5E).contains(value) { value -= 0xFEE0 }   // full-width ASCII
            if (0x30A1...0x30F6).contains(value) { value -= 0x60 }     // katakana → hiragana
            guard let folded = Unicode.Scalar(value), !ignorable.contains(folded) else { continue }
            scalars.append(folded)
        }
        return String(scalars).lowercased()
    }

    public static func contains(_ text: String, anyOf candidates: [String]) -> Bool {
        let haystack = normalize(text)
        guard !haystack.isEmpty else { return false }
        return candidates.contains { candidate in
            let needle = normalize(candidate)
            return !needle.isEmpty && haystack.contains(needle)
        }
    }

    /// Character-level similarity in 0...1 (1 − normalised Levenshtein distance).
    public static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(normalize(a))
        let y = Array(normalize(b))
        if x.isEmpty && y.isEmpty { return 1 }
        if x.isEmpty || y.isEmpty { return 0 }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
    }

    /// Best similarity against any of the references.
    public static func bestSimilarity(_ text: String, to references: [String]) -> Double {
        references.map { similarity(text, $0) }.max() ?? 0
    }

    /// True if the text contains any hiragana, katakana or CJK ideograph.
    public static func containsJapanese(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x4E00...0x9FFF, 0x3400...0x4DBF: return true
            default: return false
            }
        }
    }

    /// Words from the references that don't appear in what was heard; used for honest
    /// "these words weren't recognised" feedback in shadowing.
    public static func unrecognizedSegments(heard: String, reference: String) -> [String] {
        let separators = CharacterSet(charactersIn: "、。？！?!, 　")
        let segments = reference.components(separatedBy: separators).filter { !$0.isEmpty }
        return segments.filter { !contains(heard, anyOf: [$0]) }
    }

    /// True when a transcript is mostly Latin letters (e.g. the learner answered in English).
    public static func isMostlyLatin(_ text: String) -> Bool {
        var latin = 0
        var japanese = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A: latin += 1
            case 0x3040...0x30FF, 0x4E00...0x9FFF, 0x3400...0x4DBF: japanese += 1
            default: break
            }
        }
        return latin >= 3 && latin > japanese
    }

    /// Thinking sounds that hold the learner's turn rather than count as an answer (normalised forms).
    static let fillers: [String] = ["えーと", "ええと", "えっと", "えと", "あのう", "あのー", "あの", "うーん", "んー", "えー", "そうですね", "まあ"]
        .map { normalize($0) }
        .sorted { $0.count > $1.count }

    /// Removes leading thinking sounds; returns the normalised remainder.
    public static func stripLeadingFillers(_ text: String) -> String {
        var rest = normalize(text)
        var changed = true
        while changed && !rest.isEmpty {
            changed = false
            for filler in fillers where rest.hasPrefix(filler) {
                rest = String(rest.dropFirst(filler.count))
                changed = true
                break
            }
        }
        return rest
    }

    /// True when the utterance is only thinking sounds (「えーと」「うーん」…).
    public static func isFillerOnly(_ text: String) -> Bool {
        !normalize(text).isEmpty && stripLeadingFillers(text).isEmpty
    }

    static let smallKana: Set<Character> = Set("ゃゅょぁぃぅぇぉゎャュョァィゥェォヮ")

    /// Number of morae (sound beats) in a kana string; small ゃゅょ join the preceding kana.
    public static func moraCount(_ kana: String) -> Int {
        kana.filter { isKana($0) && !smallKana.contains($0) }.count
    }

    /// The first `count` morae of a kana string (e.g. 「じゅん」 from じゅんちょうです).
    public static func firstMorae(_ kana: String, count: Int) -> String {
        var result = ""
        var morae = 0
        for character in kana where isKana(character) {
            if smallKana.contains(character) {
                if !result.isEmpty { result.append(character) }
                continue
            }
            if morae == count { break }
            result.append(character)
            morae += 1
        }
        return result
    }

    static func isKana(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { (0x3041...0x30FF).contains($0.value) }
    }

    /// Fallback chunking when content has none: split after Japanese punctuation, keeping it attached.
    public static func punctuationChunks(_ text: String) -> [String] {
        let breaks: Set<Character> = ["、", "。", "？", "！", "?", "!"]
        var chunks: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if breaks.contains(character) {
                chunks.append(current)
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { chunks.append(current) }
        return chunks.filter { !normalize($0).isEmpty }
    }

    /// Splits an instruction into English and Japanese parts: text inside 「」 is Japanese
    /// (spoken by the Japanese voice), everything else English. The brackets are dropped.
    public static func bilingualSegments(_ text: String) -> [TextSegment] {
        var segments: [TextSegment] = []
        var current = ""
        var inJapanese = false
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            // A lone "." or ":" between brackets is not worth an utterance of its own.
            if trimmed.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) {
                segments.append(TextSegment(text: trimmed, isJapanese: inJapanese))
            }
            current = ""
        }
        for character in text {
            if character == "「" {
                flush()
                inJapanese = true
            } else if character == "」" {
                flush()
                inJapanese = false
            } else {
                current.append(character)
            }
        }
        flush()
        return segments
    }

    /// True when every bit of Japanese in an English sentence is inside 「」, so `bilingualSegments` can
    /// give each part the right voice.
    public static func isSpeakableInstruction(_ text: String) -> Bool {
        var outside = ""
        var depth = 0
        for character in text {
            if character == "「" { depth += 1 } else if character == "」" { depth = max(0, depth - 1) } else if depth == 0 { outside.append(character) }
        }
        return !containsJapanese(outside)
    }

    /// English as it should be read aloud: "Understood. / Certainly." → "Understood. or Certainly.",
    /// "Hi (to a colleague at work)." → "Hi, to a colleague at work." The screen keeps the original.
    public static func speakableEnglish(_ text: String) -> String {
        var spoken = text.replacingOccurrences(of: #"\s+/\s+"#, with: " or ", options: .regularExpression)
        spoken = spoken.replacingOccurrences(of: #"\s*\(\s*"#, with: ", ", options: .regularExpression)
        spoken = spoken.replacingOccurrences(of: #"\s*\)"#, with: "", options: .regularExpression)
        spoken = spoken.replacingOccurrences(of: #"([.?!:]),\s"#, with: "$1 ", options: .regularExpression)
        spoken = spoken.replacingOccurrences(of: #"^,\s*"#, with: "", options: .regularExpression)
        spoken = spoken.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        let trimmed = spoken.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? text : trimmed
    }
}

public struct TextSegment: Equatable, Sendable {
    public var text: String
    public var isJapanese: Bool

    public init(text: String, isJapanese: Bool) {
        self.text = text
        self.isJapanese = isJapanese
    }
}

/// Help the learner can ask for during their turn, by voice, help bar or AirPods (spec §3.4).
/// Every command is real, polite meeting Japanese, so using them is practice too.
public enum VoiceCommand: Equatable, Sendable {
    /// もう一度 (お願いします) — hear the prompt again.
    case repeatPrompt
    /// ゆっくり (お願いします) — hear it slowly.
    case slower
    /// 英語で / どういう意味ですか — hear the English.
    case english
    /// ヒント — one more step of help.
    case hint
    /// 答え / わかりません — hear the answer now.
    case answer
    /// ちょっと待って — more time to think.
    case moreTime
    /// スキップ / 次 — skip this turn.
    case skip
    /// ストップ / 一時停止 — pause the session.
    case pause

    /// Detects a command only when it is the whole utterance (16 characters or fewer, polite endings
    /// allowed), and never when the utterance matches the answer being practised, so a line like
    /// 「もう一度お願いします。」 can still be practised as a line.
    public static func detect(in transcript: String, expected: [String] = []) -> VoiceCommand? {
        let text = JapaneseText.normalize(transcript)
        guard !text.isEmpty, text.count <= 16 else { return nil }
        if !expected.isEmpty && JapaneseText.bestSimilarity(transcript, to: expected) >= 0.8 { return nil }
        func matches(_ bases: [String], tails: [String]) -> Bool {
            bases.contains { base in tails.contains { text == JapaneseText.normalize(base + $0) } }
        }
        let polite = ["", "おねがいします", "お願いします", "ください", "いってください", "言ってください", "聞かせてください"]

        if matches(["もう一度", "もういちど", "もう1度", "もう一回", "もういっかい", "リピート"], tails: polite) { return .repeatPrompt }
        if matches(["ゆっくり"], tails: polite + ["はなしてください", "話してください"]) { return .slower }
        if matches(["英語で", "えいごで"], tails: polite) { return .english }
        if matches(["どういう意味ですか", "どういういみですか", "どういう意味", "どういういみ"], tails: [""]) { return .english }
        if matches(["ヒント", "ヘルプ"], tails: ["", "ください", "お願いします", "おねがいします", "をください"]) { return .hint }
        if matches(["答え", "こたえ", "答えは", "こたえは"], tails: ["", "ください", "お願いします", "おねがいします", "は何ですか", "はなんですか"]) { return .answer }
        if matches(["わかりません", "分かりません", "わからない", "分からない"], tails: ["", "でした", "です"]) { return .answer }
        if matches(["ちょっと待って", "ちょっとまって", "待って", "まって"], tails: ["", "ください"]) { return .moreTime }
        if matches(["スキップ", "次", "つぎ", "次へ", "パス"], tails: ["", "して", "してください", "お願いします"]) { return .skip }
        if matches(["ストップ", "止めて", "とめて", "一時停止", "いちじていし", "ポーズ"], tails: ["", "ください"]) { return .pause }
        return nil
    }
}
