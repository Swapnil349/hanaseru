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
}

/// Things the learner can say during their turn instead of answering (hands-free control).
public enum VoiceCommand: Equatable, Sendable {
    case repeatPrompt
    case dontKnow
    case skip
    case pause

    public static func detect(in transcript: String) -> VoiceCommand? {
        let text = JapaneseText.normalize(transcript)
        guard !text.isEmpty, text.count <= 14 else { return nil }
        // Only whole-utterance matches count, so an answer like 「もう一度確認します」 is never taken as a command.
        func matches(_ bases: [String], tails: [String]) -> Bool {
            bases.contains { base in tails.contains { text == JapaneseText.normalize(base + $0) } }
        }
        let politeTails = ["", "おねがいします", "お願いします", "ください", "いってください", "言ってください", "聞かせてください"]

        if matches(["もう一度", "もういちど", "もう1度", "もう一回", "もういっかい", "リピート"], tails: politeTails) { return .repeatPrompt }
        if matches(["わかりません", "分かりません", "わからない", "分からない"], tails: ["", "でした", "です"]) { return .dontKnow }
        if matches(["スキップ", "次", "つぎ", "次へ", "パス"], tails: ["", "して", "してください", "お願いします"]) { return .skip }
        if matches(["ちょっと待って", "ちょっとまって", "待って", "ストップ", "止めて", "とめて"], tails: ["", "ください"]) { return .pause }
        return nil
    }
}
