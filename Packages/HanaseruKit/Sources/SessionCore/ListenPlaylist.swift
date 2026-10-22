import Foundation
import LearningCore

/// Listen (docs/LISTEN.md): a playlist of short scenes played back to back as an audio drama, for driving or chores.
/// Nothing is asked of the learner. This file decides which scenes are played and exactly what is said; the app only
/// speaks it. Pure, so the playlist can be tested without audio.

/// Each line in Japanese only, or followed by its English.
public enum ListenLanguage: String, CaseIterable, Sendable {
    case japaneseOnly
    case withEnglish

    public var title: String {
        switch self {
        case .japaneseOnly: "Japanese only"
        case .withEnglish: "Japanese + English"
        }
    }
}

/// About how long the playlist lasts.
public enum ListenLength: Int, CaseIterable, Sendable {
    case five = 5
    case ten = 10

    public var minutes: Int { rawValue }
    public var targetDuration: TimeInterval { TimeInterval(rawValue * 60) }
    public var title: String { "About \(rawValue) min" }
}

/// Where the scenes come from.
public enum ListenSource: String, CaseIterable, Sendable {
    /// The learner's own line of work.
    case myWork
    /// Everyday life (and "Money in Japan" for someone in finance).
    case everyday
    /// The learner's own scenes.
    case myScenes
    /// All of the above.
    case everything

    public var title: String {
        switch self {
        case .myWork: "My work"
        case .everyday: "Everyday"
        case .myScenes: "My scenes"
        case .everything: "Everything"
        }
    }
}

public enum ListenSpeed: String, CaseIterable, Sendable {
    case natural
    case slower

    /// Rate of the Japanese. The English always stays at normal speed.
    public var japaneseRate: Double {
        switch self {
        case .natural: 1.0
        case .slower: 0.8
        }
    }

    public var title: String {
        switch self {
        case .natural: "Natural"
        case .slower: "Slower"
        }
    }
}

/// One thing said in Listen, with the line it belongs to, for the screen.
public struct ListenUtterance: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The scene's number and title, its situation, and the closing words.
        case announcement
        /// A line of the scene, in Japanese.
        case line
        /// The English of the line just said.
        case translation
    }

    public var request: SpeechRequest
    public var kind: Kind
    /// Who says the line ("Sato", "You"); empty for announcements.
    public var speaker: String
    /// The line on screen while this is said (a translation shows the line it translates).
    public var japanese: String
    public var kana: String
    public var english: String

    public init(request: SpeechRequest, kind: Kind, speaker: String = "", japanese: String, kana: String = "",
                english: String = "") {
        self.request = request
        self.kind = kind
        self.speaker = speaker
        self.japanese = japanese
        self.kana = kana
        self.english = english
    }
}

/// One scene of the playlist and everything said in it, in order.
public struct ListenScene: Equatable, Sendable, Identifiable {
    /// The scenario's id.
    public var id: String
    public var title: String
    public var titleJa: String
    public var utterances: [ListenUtterance]

    public init(id: String, title: String, titleJa: String, utterances: [ListenUtterance]) {
        self.id = id
        self.title = title
        self.titleJa = titleJa
        self.utterances = utterances
    }

    /// Estimated time to play the scene, pauses included.
    public var estimatedDuration: TimeInterval {
        utterances.reduce(0) { $0 + ListenPlaylist.estimatedDuration(of: $1.request) }
    }
}

public struct ListenPlaylist: Equatable, Sendable {
    /// What the learner chose on the Listen screen.
    public struct Choices: Equatable, Sendable {
        public var language: ListenLanguage
        public var length: ListenLength
        public var source: ListenSource
        public var speed: ListenSpeed

        public init(language: ListenLanguage = .japaneseOnly, length: ListenLength = .five,
                    source: ListenSource = .everything, speed: ListenSpeed = .natural) {
            self.language = language
            self.length = length
            self.source = source
            self.speed = speed
        }
    }

    public var choices: Choices
    /// Where the scenes came from: the chosen source, or `.everything` when it had no scenes.
    public var source: ListenSource
    public var scenes: [ListenScene]
    /// Said after the last scene.
    public var ending: [ListenUtterance]

    public init(choices: Choices, source: ListenSource, scenes: [ListenScene], ending: [ListenUtterance]) {
        self.choices = choices
        self.source = source
        self.scenes = scenes
        self.ending = ending
    }

    public var isEmpty: Bool { scenes.isEmpty }

    /// Estimated time to play everything, pauses and the closing words included.
    public var estimatedDuration: TimeInterval {
        scenes.reduce(0) { $0 + $1.estimatedDuration }
            + ending.reduce(0) { $0 + Self.estimatedDuration(of: $1.request) }
    }

    // MARK: - Rules

    public static let minimumScenes = 3
    public static let maximumScenes = 10
    /// How many recently played scenes are remembered (and played after the others).
    public static let recentMemory = 30
    /// Silence after each line.
    public static let pauseAfterLine: TimeInterval = 0.8
    /// Silence between a Japanese line and its English.
    public static let pauseBeforeTranslation: TimeInterval = 0.4
    /// Silence between one scene and the next.
    public static let pauseBetweenScenes: TimeInterval = 2.5
    /// Said after the last scene.
    public static let endingJa = "おしまいです。お疲れさまでした。"
    public static let endingKana = "おしまいです。おつかれさまでした。"
    public static let endingEn = "That's the end. Well done."

    /// Estimated time to say a request: Japanese at 6 characters a second (at its rate), English at 2.5 words a
    /// second, plus the pause after it.
    public static func estimatedDuration(of request: SpeechRequest) -> TimeInterval {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let speaking: TimeInterval = switch request.language {
        case .japanese: Double(text.count) / 6 / max(request.rate, 0.5)
        case .english: Double(text.split(whereSeparator: \.isWhitespace).count) / 2.5
        }
        return speaking + request.pauseAfter
    }

    // MARK: - Building

    /// The playlist for these choices. Scenes not heard recently come first, in random order; those heard recently
    /// follow, longest ago first. Scenes are added until the estimated time reaches the chosen length, with at least
    /// `minimumScenes` (when there are that many) and at most `maximumScenes`.
    ///
    /// `recentlyPlayed`: ids of the scenes played lately, the latest last. `seed`: the shuffle (fixed in tests).
    public static func make(library: ContentLibrary, field: WorkField, choices: Choices, learnerName: String,
                            recentlyPlayed: [String], seed: UInt64 = UInt64.random(in: 0...UInt64.max)) -> ListenPlaylist {
        var source = choices.source
        var pool = scenarios(in: library, field: field, source: source)
        if pool.isEmpty {
            source = .everything
            pool = scenarios(in: library, field: field, source: .everything)
        }

        var generator = SplitMix64(seed: seed)
        let shuffled = pool.shuffled(using: &generator)
        var lastHeard: [String: Int] = [:]
        for (index, id) in recentlyPlayed.suffix(recentMemory).enumerated() { lastHeard[id] = index }
        let fresh = shuffled.filter { lastHeard[$0.id] == nil }
        let heard = shuffled.filter { lastHeard[$0.id] != nil }
            .sorted { (lastHeard[$0.id] ?? 0) < (lastHeard[$1.id] ?? 0) }

        var scenes: [ListenScene] = []
        var total: TimeInterval = 0
        for scenario in fresh + heard {
            if scenes.count >= maximumScenes { break }
            if scenes.count >= minimumScenes && total >= choices.length.targetDuration { break }
            let next = Self.scene(scenario, number: scenes.count + 1, library: library, choices: choices,
                                  learnerName: learnerName)
            // A scene with nothing to say is left out.
            guard next.utterances.contains(where: { $0.kind == .line }) else { continue }
            scenes.append(next)
            total += next.estimatedDuration
        }
        return ListenPlaylist(choices: choices, source: source, scenes: scenes,
                              ending: scenes.isEmpty ? [] : Self.ending(choices))
    }

    /// The scenes a source offers someone in this line of work.
    public static func scenarios(in library: ContentLibrary, field: WorkField, source: ListenSource) -> [Scenario] {
        let playable = library.scenarios.filter { !$0.beats.isEmpty }
        switch source {
        case .myWork:
            return playable.filter { !$0.isLearnersOwn && $0.track == .work && $0.workField == field }
        case .everyday:
            // Someone in finance also gets "Money in Japan" (everyday scenes written for finance).
            return playable.filter { scenario in
                !scenario.isLearnersOwn && scenario.track == .everyday
                    && (scenario.workField == nil || scenario.workField == field)
            }
        case .myScenes:
            return playable.filter(\.isLearnersOwn)
        case .everything:
            // Another field's scenes are left out, as in planned sessions.
            return playable.filter { $0.workField == nil || $0.workField == field || $0.isLearnersOwn }
        }
    }

    /// Everything said for one scene: the announcement, then every line of the script in order.
    public static func scene(_ scenario: Scenario, number: Int, library: ContentLibrary, choices: Choices,
                             learnerName: String) -> ListenScene {
        let withEnglish = choices.language == .withEnglish
        let rate = choices.speed.japaneseRate
        let persona = library.persona(id: scenario.personaID)
        let partnerName = persona.map { $0.nameEn.isEmpty ? $0.nameJa : $0.nameEn } ?? "Colleague"
        let gender = persona?.voiceGender
        let title = filled(scenario.title, name: learnerName)
        let titleJa = filled(scenario.titleJa, name: learnerName)
        var utterances: [ListenUtterance] = []

        // 1. The announcement.
        if withEnglish {
            utterances.append(ListenUtterance(
                request: english("Scene \(number): \(sentence(title))", pauseAfter: pauseBeforeTranslation),
                kind: .announcement, japanese: titleJa, english: title))
            if !titleJa.isEmpty {
                utterances.append(ListenUtterance(
                    request: SpeechRequest(text: titleJa, language: .japanese, rate: rate, pauseAfter: pauseAfterLine,
                                           voice: .coachJapanese),
                    kind: .announcement, japanese: titleJa, english: title))
            }
            let situation = filled(scenario.situationEn, name: learnerName)
            if !situation.isEmpty {
                utterances.append(ListenUtterance(request: english(situation, pauseAfter: pauseAfterLine),
                                                  kind: .announcement, japanese: titleJa, english: situation))
            }
        } else {
            let announcement = titleJa.isEmpty ? "場面\(number)。" : "場面\(number)。\(titleJa)。"
            utterances.append(ListenUtterance(
                request: SpeechRequest(text: announcement, language: .japanese, rate: rate, pauseAfter: pauseAfterLine,
                                       voice: .coachJapanese),
                kind: .announcement, japanese: titleJa.isEmpty ? announcement : titleJa, english: title))
        }

        // 2. Every line: the partner's (in their voice), the learner's first answer (the coach's Japanese voice),
        //    then the closing line.
        func add(_ japanese: String, kana: String, english meaning: String, partner: Bool) {
            let text = filled(japanese, name: learnerName)
            guard !text.isEmpty else { return }
            let reading = filled(kana, name: learnerName)
            let translation = filled(meaning, name: learnerName)
            let translated = withEnglish && !translation.isEmpty
            let pause = translated ? pauseBeforeTranslation : pauseAfterLine
            var request: SpeechRequest = partner ? .partner(text, gender: gender, rate: rate) : .model(text, rate: rate)
            request.pauseAfter = pause
            let speaker = partner ? partnerName : "You"
            utterances.append(ListenUtterance(request: request, kind: .line, speaker: speaker, japanese: text,
                                              kana: reading, english: translation))
            if translated {
                utterances.append(ListenUtterance(request: Self.english(translation, pauseAfter: pauseAfterLine),
                                                  kind: .translation, speaker: speaker, japanese: text, kana: reading,
                                                  english: translation))
            }
        }
        for beat in scenario.beats {
            add(beat.line, kana: beat.kana, english: beat.english, partner: true)
            if let answer = beat.responses.first {
                add(answer.japanese, kana: answer.kana, english: answer.english, partner: false)
            }
        }
        add(scenario.closingLine, kana: scenario.closingKana, english: scenario.closingEnglish, partner: true)

        // 3. A longer silence before the next scene.
        if !utterances.isEmpty { utterances[utterances.count - 1].request.pauseAfter = pauseBetweenScenes }
        return ListenScene(id: scenario.id, title: title, titleJa: titleJa, utterances: utterances)
    }

    /// Said after the last scene.
    public static func ending(_ choices: Choices) -> [ListenUtterance] {
        var said = [ListenUtterance(
            request: SpeechRequest(text: endingJa, language: .japanese, rate: choices.speed.japaneseRate,
                                   pauseAfter: pauseAfterLine, voice: .coachJapanese),
            kind: .announcement, japanese: endingJa, kana: endingKana, english: endingEn)]
        if choices.language == .withEnglish {
            said.append(ListenUtterance(request: english(endingEn, pauseAfter: pauseAfterLine), kind: .announcement,
                                        japanese: endingJa, kana: endingKana, english: endingEn))
        }
        return said
    }

    /// The ids played lately with `id` added as the latest, keeping the last `recentMemory`.
    public static func remembering(_ id: String, in recent: [String]) -> [String] {
        Array((recent.filter { $0 != id } + [id]).suffix(recentMemory))
    }

    /// `{name}` filled with the learner's name, or, without a name, left out (with its さん and comma).
    public static func filled(_ text: String, name: String) -> String {
        guard text.contains("{name}") else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty else {
            return text.replacingOccurrences(of: "{name}", with: name).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var result = text
        for placeholder in ["{name}さん、", "{name}さん", "{name}様", "{name}, ", ", {name}", "{name}"] {
            result = result.replacingOccurrences(of: placeholder, with: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func english(_ text: String, pauseAfter: TimeInterval) -> SpeechRequest {
        SpeechRequest(text: text, language: .english, rate: 1.0, pauseAfter: pauseAfter, voice: .coachEnglish)
    }

    /// The text ending in a full stop (unless it already ends in punctuation).
    private static func sentence(_ text: String) -> String {
        guard let last = text.last else { return text }
        return ".?!".contains(last) ? text : text + "."
    }
}

/// A small seeded random generator, so a shuffle can be repeated in tests.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
