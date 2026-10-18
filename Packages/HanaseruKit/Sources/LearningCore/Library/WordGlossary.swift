import Foundation

/// One word (or set phrase) of a line, with its reading and its meaning in that line.
public struct WordGloss: Codable, Hashable, Sendable {
    public var ja: String
    public var kana: String
    public var en: String

    public init(ja: String, kana: String, en: String) {
        self.ja = ja
        self.kana = kana
        self.en = en
    }

    /// The reading in English letters, with particles as they're said (は → wa).
    public var romaji: String {
        kana.contains(where: Romaji.isKanaLetter) ? Romaji.romanize(kana) : kana
    }
}

public extension ContentLibrary {
    /// The words of a line in order, with their meanings, or empty when the line has no glossary.
    /// A line with the learner's name in it ("{name}です") is found whatever the name is.
    func words(in japanese: String) -> [WordGloss] {
        if let words = glossary[japanese] { return words }
        for (key, words) in glossary where key.contains("{name}") {
            let parts = key.components(separatedBy: "{name}")
            guard parts.count == 2, japanese.count >= parts[0].count + parts[1].count,
                  japanese.hasPrefix(parts[0]), japanese.hasSuffix(parts[1]) else { continue }
            let name = String(japanese.dropFirst(parts[0].count).dropLast(parts[1].count))
            guard !name.isEmpty else { continue }
            return words.map { word in
                guard word.ja == "{name}" else { return word }
                return WordGloss(ja: name, kana: name, en: word.en)
            }
        }
        return []
    }
}

extension Romaji {
    static func isKanaLetter(_ character: Character) -> Bool {
        isHiragana(character) || isHiragana(toHiragana(character))
    }
}
