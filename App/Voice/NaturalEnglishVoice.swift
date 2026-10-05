import Foundation

/// The coach's English, pre-recorded with a neural voice (see tools/voice/build_clips.py) and bundled in
/// the app, so it sounds natural rather than like the built-in speech engine. Anything not recorded
/// (e.g. the learner's own phrases) falls back to the iPhone voice.
final class NaturalEnglishVoice: @unchecked Sendable {
    static let shared = NaturalEnglishVoice()

    let voiceName: String
    private let clips: [String: String]

    private init() {
        struct Index: Decodable {
            var voice: String
            var clips: [String: String]
        }
        if let url = Bundle.main.url(forResource: "english-voice-index", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let index = try? JSONDecoder().decode(Index.self, from: data) {
            voiceName = index.voice
            clips = index.clips
        } else {
            voiceName = ""
            clips = [:]
        }
    }

    var count: Int { clips.count }
    var isAvailable: Bool { !clips.isEmpty }

    /// On unless the learner switched it off in Settings.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.naturalEnglish) as? Bool ?? true
    }

    /// The recordings that make up `text`: the whole sentence, or a head ("Say:", "Part 2 of 5:", "Listen.")
    /// followed by the rest, or a list split at ", " / " and ". Nil when any part isn't recorded, so a
    /// sentence is never half natural voice and half iPhone voice.
    func recordings(for text: String) -> [URL]? {
        guard isAvailable else { return nil }
        return pieces(of: text, depth: 0)?.compactMap { name in
            Bundle.main.url(forResource: name, withExtension: nil)
        }
    }

    private func pieces(of text: String, depth: Int) -> [String]? {
        let whole = Self.key(text)
        guard !whole.isEmpty else { return [] }
        if let clip = clips[whole] { return [clip] }
        guard depth < 6 else { return nil }
        for separator in [": ", ". ", ", ", " and "] {
            guard let range = text.range(of: separator) else { continue }
            let head = String(text[..<range.lowerBound]) + separator.trimmingCharacters(in: .whitespaces)
            let tail = String(text[range.upperBound...])
            if let headClip = clips[Self.key(head)], let rest = pieces(of: tail, depth: depth + 1) {
                return [headClip] + rest
            }
        }
        return nil
    }

    /// Same as `key()` in tools/voice/build_clips.py.
    static func key(_ text: String) -> String {
        var t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: CharacterSet(charactersIn: " .!?:,;\u{2026}\u{2014}-\""))
    }
}
