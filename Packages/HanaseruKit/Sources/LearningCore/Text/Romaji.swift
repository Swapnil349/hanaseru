import Foundation

/// Japanese written in English letters — modified Hepburn with long vowels marked, as in the course content:
/// 「いいえ、特に問題はありません。」 → "Iie, toku ni mondai wa arimasen."
public enum Romaji {
    /// A sentence in romaji, split into words, with particles as they're said (は → wa, へ → e, を → o).
    /// `kana` is the reading of `japanese`; it can be empty when `japanese` is all kana. Returns "" when there
    /// is no reading (kanji without kana).
    public static func of(_ japanese: String, kana: String) -> String {
        let key = (japanese + "|" + kana) as NSString
        if let cached = cache.object(forKey: key) { return cached as String }
        let result = make(japanese, kana: kana)
        cache.setObject(result as NSString, forKey: key)
        return result
    }

    nonisolated(unsafe) private static let cache = NSCache<NSString, NSString>()

    static func make(_ japanese: String, kana: String) -> String {
        let reading = kana.isEmpty ? japanese : kana
        guard !reading.isEmpty, !reading.contains(where: isKanji) else { return "" }
        return sentence(words(japanese: japanese.isEmpty ? reading : japanese, kana: reading))
    }

    // MARK: - Words

    /// A word's reading and how it is written.
    struct Piece {
        var kana: String
        var surface: String
    }

    /// The reading split into words: the system's Japanese tokenizer finds the words in `japanese`, and their
    /// readings are taken from `kana` (which the content got right), so a word is never misread.
    static func words(japanese: String, kana: String) -> [String] {
        #if canImport(Darwin)
        if let aligned = alignedWords(japanese: japanese, kana: kana) { return glue(aligned) }
        #endif
        return glue(fallbackWords(kana).map { Piece(kana: $0, surface: $0) })
    }

    /// Without the tokenizer, words end at punctuation.
    static func fallbackWords(_ kana: String) -> [String] {
        var words: [String] = []
        var current = ""
        for character in kana {
            if isPunctuation(character) || character == " " || character == "　" {
                if !current.isEmpty { words.append(current) }
                current = ""
                if character != " " && character != "　" { words.append(String(character)) }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    #if canImport(Darwin)
    private struct Token {
        var surface: String
        /// The tokenizer's reading in hiragana (kanji words only).
        var reading: String
        var hasKanji: Bool
    }

    private static func tokens(_ text: String) -> [Token] {
        let string = text as NSString
        let tokenizer = CFStringTokenizerCreate(nil, text as CFString, CFRange(location: 0, length: string.length),
                                                kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja") as CFLocale)
        var tokens: [Token] = []
        var position = 0
        func gap(upTo end: Int) {
            guard end > position else { return }
            let piece = string.substring(with: NSRange(location: position, length: end - position))
            for character in piece where character != " " && character != "　" {
                tokens.append(Token(surface: String(character), reading: "", hasKanji: false))
            }
        }
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            gap(upTo: range.location)
            let surface = string.substring(with: NSRange(location: range.location, length: range.length))
            position = range.location + range.length
            let trimmed = surface.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let hasKanji = trimmed.contains(where: isKanji)
            var reading = ""
            if hasKanji, let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String {
                reading = latin.applyingTransform(.latinToHiragana, reverse: false) ?? ""
            }
            if !hasKanji && trimmed.count > 1 && trimmed.allSatisfy(isPunctuation) {
                for character in trimmed { tokens.append(Token(surface: String(character), reading: "", hasKanji: false)) }
            } else {
                tokens.append(Token(surface: trimmed, reading: reading, hasKanji: hasKanji))
            }
        }
        gap(upTo: string.length)
        return tokens
    }

    /// Words of `kana`, at the word boundaries of `japanese`. Nil when the two can't be lined up.
    static func alignedWords(japanese: String, kana: String) -> [Piece]? {
        let tokens = tokens(japanese)
        guard !tokens.isEmpty else { return nil }
        let reading = Array(kana)
        let plain = reading.map(toHiragana)
        var position = 0
        var words: [Piece] = []

        func skipSpaces() {
            while position < reading.count && (reading[position] == " " || reading[position] == "　") { position += 1 }
        }
        func matches(_ text: String, at start: Int) -> Bool {
            let wanted = text.map(toHiragana)
            guard !wanted.isEmpty, start + wanted.count <= plain.count else { return false }
            return Array(plain[start..<(start + wanted.count)]) == wanted
        }
        func find(_ text: String, from start: Int) -> Int? {
            var index = start
            while index < plain.count {
                if matches(text, at: index) { return index }
                index += 1
            }
            return nil
        }

        var index = 0
        while index < tokens.count {
            skipSpaces()
            let token = tokens[index]
            if !token.hasKanji {
                // Kana, punctuation and Latin letters appear as they are in the reading.
                guard matches(token.surface, at: position) else { return nil }
                let count = token.surface.count
                words.append(Piece(kana: String(reading[position..<(position + count)]), surface: token.surface))
                position += count
                index += 1
                continue
            }
            if matches(token.reading, at: position) {
                let count = token.reading.count
                words.append(Piece(kana: String(reading[position..<(position + count)]), surface: token.surface))
                position += count
                index += 1
                continue
            }
            // The tokenizer read it differently: the kanji words up to the next kana or punctuation take the
            // reading in between, as one word.
            var next = index + 1
            while next < tokens.count && tokens[next].hasKanji { next += 1 }
            let end: Int
            if next < tokens.count {
                guard let found = find(tokens[next].surface, from: position + 1) else { return nil }
                end = found
            } else {
                end = reading.count
            }
            guard end > position else { return nil }
            let surface = tokens[index..<next].map { $0.surface }.joined()
            words.append(Piece(kana: String(reading[position..<end]), surface: surface))
            position = end
            index = next
        }
        skipSpaces()
        if position < reading.count {
            let rest = String(reading[position...])
            words.append(Piece(kana: rest, surface: rest))
        }
        return words
    }
    #endif

    /// Endings written together with the word before them (ari-masen, okut-te, tanoshikat-ta).
    static let endings: Set<String> = [
        "ます", "まし", "ませ", "ましょ", "ましょう", "ん", "た", "て", "ない", "なかっ", "なく", "なけれ",
        "たい", "たく", "たかっ", "う", "よう", "れ", "られ", "せ", "させ", "ば", "ちゃ", "ちゃう", "たら", "たり",
        "ず", "ぬ",
    ]

    /// Joins endings to their word, and the polite prefixes お／ご to the word after them.
    static func glue(_ pieces: [Piece]) -> [String] {
        var result: [Piece] = []
        var prefix: Piece?
        for piece in pieces {
            let plain = String(piece.kana.map(toHiragana))
            if plain == "お" || plain == "ご" {
                prefix = Piece(kana: (prefix?.kana ?? "") + piece.kana, surface: (prefix?.surface ?? "") + piece.surface)
                continue
            }
            let joined = Piece(kana: (prefix?.kana ?? "") + piece.kana, surface: (prefix?.surface ?? "") + piece.surface)
            prefix = nil
            if let last = result.last, !isPunctuationWord(last.kana) {
                let lastPlain = String(last.kana.map(toHiragana))
                // で／だ after a verb stem ending in ん is the verb's ending (住んで, 進んだ); after anything else
                // it's a particle or "is" (新幹線で, そうだ).
                let verbalDe = (plain == "で" || plain == "だ") && last.surface.hasSuffix("ん")
                    && last.surface.contains(where: isKanji)
                if endings.contains(plain) || verbalDe || lastPlain.hasSuffix("っ") {
                    result[result.count - 1] = Piece(kana: last.kana + joined.kana, surface: last.surface + joined.surface)
                    continue
                }
            }
            result.append(joined)
        }
        if let prefix { result.append(prefix) }
        return result.map { $0.kana }
    }

    // MARK: - Sentence

    static func sentence(_ words: [String]) -> String {
        var output = ""
        var capitalize = true
        var quoteOpen = false
        for word in words {
            if isPunctuationWord(word), let character = word.first {
                let mark = punctuation(character)
                if mark == "\"" {
                    if !quoteOpen && !output.isEmpty && !output.hasSuffix(" ") { output += " " }
                    output += "\""
                    quoteOpen.toggle()
                } else if mark == "(" {
                    if !output.isEmpty && !output.hasSuffix(" ") { output += " " }
                    output += "("
                } else {
                    output += mark
                }
                if mark == "." || mark == "?" || mark == "!" { capitalize = true }
                continue
            }
            var text = romanize(word)
            guard !text.isEmpty else { continue }
            if capitalize {
                text = text.prefix(1).uppercased() + String(text.dropFirst())
                capitalize = false
            }
            let opening = output.hasSuffix("(") || (quoteOpen && output.hasSuffix("\""))
            if !output.isEmpty && !output.hasSuffix(" ") && !opening { output += " " }
            output += text
        }
        return output.trimmingCharacters(in: .whitespaces)
    }

    /// One word, with particles as said (は → wa, へ → e, を → o), including a は that ends a word (では, 実は).
    static func romanize(_ word: String) -> String {
        let plain = String(word.map(toHiragana))
        if plain == "は" { return "wa" }
        if plain == "へ" { return "e" }
        if plain == "を" { return "o" }
        if plain.count > 1 && plain.hasSuffix("は") && word.last.map(isHiragana) == true {
            return fromKana(String(word.dropLast())) + "wa"
        }
        return fromKana(word)
    }

    // MARK: - Kana

    /// Kana to romaji, with no word splitting: 「しんかんせん」 → "shinkansen", 「きょう」 → "kyō".
    public static func fromKana(_ kana: String) -> String {
        var syllables: [String] = []
        let characters = kana.map(toHiragana)
        var index = 0
        var doubleNext = false
        while index < characters.count {
            let character = characters[index]
            if character == "っ" {
                doubleNext = true
                index += 1
                continue
            }
            if character == "ー" {
                if let last = syllables.popLast() { syllables.append(lengthened(last)) }
                index += 1
                continue
            }
            guard var syllable = base[character] else {
                // Not kana: letters, digits and anything else pass through.
                syllables.append(String(halfWidth(character)))
                doubleNext = false
                index += 1
                continue
            }
            // Digraphs: きゃ → kya, しゃ → sha, ふぁ → fa, てぃ → ti.
            if index + 1 < characters.count, let small = smallVowels[characters[index + 1]] {
                syllable = combine(syllable, small)
                index += 1
            }
            if doubleNext {
                syllable = (syllable.hasPrefix("ch") ? "t" : String(syllable.prefix(1))) + syllable
                doubleNext = false
            }
            // Long vowels: おう and おお → ō, うう → ū.
            if let last = syllables.last, isLongVowel(syllable, after: last) {
                syllables[syllables.count - 1] = lengthened(last)
                index += 1
                continue
            }
            syllables.append(syllable)
            index += 1
        }
        // ん before a vowel or y is written n' (kon'ya, gen'in).
        var output = ""
        for (position, syllable) in syllables.enumerated() {
            output += syllable
            if syllable == "n", position + 1 < syllables.count, let next = syllables[position + 1].first,
               "aeiouyāēīōū".contains(next) {
                output += "'"
            }
        }
        return output
    }

    static func isLongVowel(_ syllable: String, after last: String) -> Bool {
        if syllable == "u" { return last.hasSuffix("o") || last.hasSuffix("u") }
        if syllable == "o" { return last.hasSuffix("o") }
        return false
    }

    static let macrons: [Character: Character] = ["a": "ā", "i": "ī", "u": "ū", "e": "ē", "o": "ō"]

    static func lengthened(_ syllable: String) -> String {
        guard let vowel = syllable.last, let long = macrons[vowel] else { return syllable }
        return String(syllable.dropLast()) + String(long)
    }

    static func combine(_ syllable: String, _ small: String) -> String {
        if small.hasPrefix("y") {
            // し, ち and じ drop their i (sha, cha, ja); others keep a y (kya, nyu, ryo).
            if syllable == "shi" || syllable == "chi" || syllable == "ji" {
                return String(syllable.dropLast()) + String(small.dropFirst())
            }
            if syllable.hasSuffix("i") { return String(syllable.dropLast()) + small }
            return syllable + small
        }
        if syllable == "u" { return "w" + small }
        guard let last = syllable.last, "aiueo".contains(last) else { return syllable + small }
        return String(syllable.dropLast()) + small
    }

    static let smallVowels: [Character: String] = [
        "ゃ": "ya", "ゅ": "yu", "ょ": "yo", "ぁ": "a", "ぃ": "i", "ぅ": "u", "ぇ": "e", "ぉ": "o", "ゎ": "wa",
    ]

    static let base: [Character: String] = [
        "あ": "a", "い": "i", "う": "u", "え": "e", "お": "o",
        "か": "ka", "き": "ki", "く": "ku", "け": "ke", "こ": "ko",
        "が": "ga", "ぎ": "gi", "ぐ": "gu", "げ": "ge", "ご": "go",
        "さ": "sa", "し": "shi", "す": "su", "せ": "se", "そ": "so",
        "ざ": "za", "じ": "ji", "ず": "zu", "ぜ": "ze", "ぞ": "zo",
        "た": "ta", "ち": "chi", "つ": "tsu", "て": "te", "と": "to",
        "だ": "da", "ぢ": "ji", "づ": "zu", "で": "de", "ど": "do",
        "な": "na", "に": "ni", "ぬ": "nu", "ね": "ne", "の": "no",
        "は": "ha", "ひ": "hi", "ふ": "fu", "へ": "he", "ほ": "ho",
        "ば": "ba", "び": "bi", "ぶ": "bu", "べ": "be", "ぼ": "bo",
        "ぱ": "pa", "ぴ": "pi", "ぷ": "pu", "ぺ": "pe", "ぽ": "po",
        "ま": "ma", "み": "mi", "む": "mu", "め": "me", "も": "mo",
        "や": "ya", "ゆ": "yu", "よ": "yo",
        "ら": "ra", "り": "ri", "る": "ru", "れ": "re", "ろ": "ro",
        "わ": "wa", "ゐ": "i", "ゑ": "e", "を": "o", "ん": "n", "ゔ": "vu",
        "ぁ": "a", "ぃ": "i", "ぅ": "u", "ぇ": "e", "ぉ": "o", "ゃ": "ya", "ゅ": "yu", "ょ": "yo", "ゎ": "wa",
    ]

    // MARK: - Characters

    static func toHiragana(_ character: Character) -> Character {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first,
              (0x30A1...0x30F6).contains(scalar.value),
              let hiragana = Unicode.Scalar(scalar.value - 0x60) else { return character }
        return Character(hiragana)
    }

    static func isHiragana(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return (0x3041...0x309F).contains(scalar.value)
    }

    static func isKanji(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value) || scalar.value == 0x3005
    }

    static func isPunctuation(_ character: Character) -> Bool {
        "、。，．,.？?！!・「」『』（）()…〜~：:".contains(character)
    }

    static func isPunctuationWord(_ word: String) -> Bool {
        word.count == 1 && word.first.map(isPunctuation) == true
    }

    static func punctuation(_ character: Character) -> String {
        switch character {
        case "、", "，", ",", "・": return ","
        case "。", "．", ".": return "."
        case "？", "?": return "?"
        case "！", "!": return "!"
        case "「", "」", "『", "』": return "\""
        case "（", "(": return "("
        case "）", ")": return ")"
        case "…": return "..."
        case "〜", "~": return "~"
        case "：", ":": return ":"
        default: return String(character)
        }
    }

    /// Full-width letters and digits as ordinary ones.
    static func halfWidth(_ character: Character) -> Character {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first,
              (0xFF01...0xFF5E).contains(scalar.value),
              let narrow = Unicode.Scalar(scalar.value - 0xFEE0) else { return character }
        return Character(narrow)
    }
}
