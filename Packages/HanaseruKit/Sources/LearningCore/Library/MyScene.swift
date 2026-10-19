import Foundation

/// The learner's own scene: a conversation or a speech they described in English, written by the AI coach
/// (docs/MY-SCENES.md). It is saved on the device in this exact shape, which every platform shares, so scenes
/// can be exported and imported between the iPhone, Android and Windows apps.
public struct MyScene: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// The learner and someone else take turns.
        case conversation
        /// The learner speaks alone: a self-introduction, a presentation, a speech.
        case monologue
    }

    /// Every saved scene's id starts with this, so it can't clash with the app's own scenes.
    public static let idPrefix = "my."

    public var id: String
    public var kind: Kind
    /// What the learner asked for, in English, with each later change after "Changed:".
    public var description: String
    /// Milliseconds since 1970, as on the other platforms.
    public var createdAt: Double
    public var updatedAt: Double
    public var result: SceneResult

    public init(id: String, kind: Kind, description: String, createdAt: Double, updatedAt: Double, result: SceneResult) {
        self.id = id
        self.kind = kind
        self.description = description
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.result = result
    }

    /// Forgiving, because files come from other apps and versions: only the id and a scene with lines are required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        guard id.hasPrefix(Self.idPrefix) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Not one of the learner's scenes")
        }
        let scene = try c.decode(SceneResult.self, forKey: .result)
        guard !scene.beats.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .result, in: c, debugDescription: "A scene without lines")
        }
        result = scene
        kind = (try? c.decode(Kind.self, forKey: .kind))
            ?? (scene.beats.allSatisfy { $0.partner.isEmpty } ? .monologue : .conversation)
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        let created = Self.decodeTime(c, .createdAt) ?? Self.milliseconds(Date())
        createdAt = created
        updatedAt = Self.decodeTime(c, .updatedAt) ?? created
    }

    private enum CodingKeys: String, CodingKey { case id, kind, description, createdAt, updatedAt, result }

    /// A time as milliseconds since 1970, or as an ISO 8601 date.
    private static func decodeTime(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
        if let milliseconds = try? c.decode(Double.self, forKey: key) { return milliseconds }
        guard let text = try? c.decode(String.self, forKey: key) else { return nil }
        if let milliseconds = Double(text) { return milliseconds }
        return ISO8601DateFormatter().date(from: text).map { Self.milliseconds($0) }
    }

    public static func milliseconds(_ date: Date) -> Double {
        (date.timeIntervalSince1970 * 1000).rounded()
    }

    public var createdDate: Date { Date(timeIntervalSince1970: createdAt / 1000) }
    public var updatedDate: Date { Date(timeIntervalSince1970: updatedAt / 1000) }

    /// A fresh id: "my." and twelve random letters and digits.
    public static func newID() -> String {
        idPrefix + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
    }

    /// The scene the coach wrote, saved: a new one, or `previous` changed as `description` asked.
    public static func saved(_ result: SceneResult, kind: Kind, description: String, replacing previous: MyScene? = nil,
                             now: Date = Date()) -> MyScene {
        let time = milliseconds(now)
        let asked = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return MyScene(
            id: previous?.id ?? newID(),
            kind: previous?.kind ?? kind,
            description: previous.map { $0.description.isEmpty ? "Changed: " + asked : $0.description + "\nChanged: " + asked }
                ?? asked,
            createdAt: previous?.createdAt ?? time,
            updatedAt: time,
            result: result
        )
    }

    /// No one else speaks.
    public var isMonologue: Bool {
        kind == .monologue || result.beats.allSatisfy { $0.partner.isEmpty }
    }

    /// The coach's scene as JSON, sent back when the learner asks for a change.
    public func resultJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(result), as: UTF8.self)
    }

    // MARK: - Files

    public enum FileError: Error, Equatable, LocalizedError {
        case noScenes

        public var errorDescription: String? {
            switch self {
            case .noScenes: "No scenes were found in that file."
            }
        }
    }

    /// Scenes from an exported file: one scene, or a list of them. Entries that aren't scenes are left out.
    public static func scenes(fromFile data: Data) throws -> [MyScene] {
        struct Entry: Decodable {
            let scene: MyScene?
            init(from decoder: Decoder) {
                scene = try? MyScene(from: decoder)
            }
        }
        let decoder = JSONDecoder()
        if let list = try? decoder.decode([Entry].self, from: data) {
            let scenes = list.compactMap(\.scene)
            guard !scenes.isEmpty else { throw FileError.noScenes }
            return scenes
        }
        guard let scene = try? decoder.decode(MyScene.self, from: data) else { throw FileError.noScenes }
        return [scene]
    }

    /// Scenes as a file to share: one scene as an object, several as a list (both import everywhere).
    public static func file(_ scenes: [MyScene]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if scenes.count == 1, let scene = scenes.first { return try encoder.encode(scene) }
        return try encoder.encode(scenes)
    }
}

/// A scene as the coach writes it (POST /v1/scene). In a monologue every `partner` line and the `closing` are empty.
/// Lines may contain `{name}`, the learner's name.
public struct SceneResult: Codable, Hashable, Sendable {
    /// One line, with its reading, its meaning and its words.
    public struct Line: Codable, Hashable, Sendable {
        public var japanese: String
        public var kana: String
        public var english: String
        public var words: [WordGloss]

        public init(japanese: String = "", kana: String = "", english: String = "", words: [WordGloss] = []) {
            self.japanese = japanese
            self.kana = kana
            self.english = english
            self.words = words
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            japanese = (try? c.decode(String.self, forKey: .japanese)) ?? ""
            kana = (try? c.decode(String.self, forKey: .kana)) ?? ""
            english = (try? c.decode(String.self, forKey: .english)) ?? ""
            words = (try? c.decode([WordGloss].self, forKey: .words)) ?? []
        }

        private enum CodingKeys: String, CodingKey { case japanese, kana, english, words }

        /// No one says anything (the other person in a monologue).
        public var isEmpty: Bool { japanese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The other person's line and the learner's answer.
    public struct Beat: Codable, Hashable, Sendable {
        public var partner: Line
        public var learner: Line
        /// A short English hint for the learner's line ("Say your name").
        public var hintEn: String

        public init(partner: Line = Line(), learner: Line, hintEn: String) {
            self.partner = partner
            self.learner = learner
            self.hintEn = hintEn
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            partner = (try? c.decode(Line.self, forKey: .partner)) ?? Line()
            learner = try c.decode(Line.self, forKey: .learner)
            hintEn = (try? c.decode(String.self, forKey: .hintEn)) ?? ""
        }

        private enum CodingKeys: String, CodingKey { case partner, learner, hintEn }
    }

    public var title: String
    public var titleJa: String
    public var situationEn: String
    public var placeEn: String
    public var partnerNameJa: String
    public var partnerNameEn: String
    public var partnerRole: String
    /// "male" or "female".
    public var partnerGender: String
    /// "work" or "everyday".
    public var track: String
    public var beats: [Beat]
    public var closing: Line

    public init(title: String, titleJa: String = "", situationEn: String = "", placeEn: String = "",
                partnerNameJa: String = "", partnerNameEn: String = "", partnerRole: String = "",
                partnerGender: String = "female", track: String = "everyday", beats: [Beat], closing: Line = Line()) {
        self.title = title
        self.titleJa = titleJa
        self.situationEn = situationEn
        self.placeEn = placeEn
        self.partnerNameJa = partnerNameJa
        self.partnerNameEn = partnerNameEn
        self.partnerRole = partnerRole
        self.partnerGender = partnerGender
        self.track = track
        self.beats = beats
        self.closing = closing
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String { (try? c.decode(String.self, forKey: key)) ?? "" }
        title = text(.title)
        titleJa = text(.titleJa)
        situationEn = text(.situationEn)
        placeEn = text(.placeEn)
        partnerNameJa = text(.partnerNameJa)
        partnerNameEn = text(.partnerNameEn)
        partnerRole = text(.partnerRole)
        partnerGender = text(.partnerGender)
        track = text(.track)
        beats = try c.decode([Beat].self, forKey: .beats)
        closing = (try? c.decode(Line.self, forKey: .closing)) ?? Line()
    }

    private enum CodingKeys: String, CodingKey {
        case title, titleJa, situationEn, placeEn, partnerNameJa, partnerNameEn, partnerRole, partnerGender, track, beats,
             closing
    }
}

/// A saved scene as the app's own content: an ordinary scenario, the other person, and the words of every line.
public struct MySceneLesson: Sendable {
    public var scenario: Scenario
    public var persona: Persona
    /// Each line's words, by the line's Japanese (the learner's lines keep `{name}`, as built-in scenes do).
    public var glossary: [String: [WordGloss]]
}

public extension MyScene {
    /// The level the coach writes for, as far as planning goes (it writes at the learner's own level).
    static let lessonLevel = 3

    /// The scene as a scenario the app teaches like any other (see docs/MY-SCENES.md). `learnerName` fills
    /// `{name}` in the other person's lines; the learner's own lines keep it and are filled when practised.
    func lesson(learnerName: String = "") -> MySceneLesson {
        let personaID = id + ".partner"
        var glossary: [String: [WordGloss]] = [:]
        func addWords(_ line: SceneResult.Line, japanese: String) {
            guard !japanese.isEmpty, !line.words.isEmpty, glossary[japanese] == nil else { return }
            glossary[japanese] = line.words
        }

        var beats: [ScenarioBeat] = []
        for beat in result.beats where !beat.learner.isEmpty {
            let partner = Self.named(beat.partner, learnerName)
            let hint = beat.hintEn.trimmingCharacters(in: .whitespacesAndNewlines)
            beats.append(ScenarioBeat(
                id: "b" + String(beats.count + 1), line: partner.japanese, kana: partner.kana, english: partner.english,
                hintEn: hint.isEmpty ? beat.learner.english : hint,
                responses: [ModelLine(japanese: beat.learner.japanese, kana: beat.learner.kana, english: beat.learner.english)],
                intentEn: hint.isEmpty ? nil : hint
            ))
            addWords(partner, japanese: partner.japanese)
            addWords(beat.learner, japanese: beat.learner.japanese)
        }
        let closing = Self.named(result.closing, learnerName)
        addWords(closing, japanese: closing.japanese)

        let title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = result.placeEn.trimmingCharacters(in: .whitespacesAndNewlines)
        let scenario = Scenario(
            id: id, title: title.isEmpty ? "My scene" : title, titleJa: result.titleJa,
            track: Track(rawValue: result.track) ?? .everyday, level: Self.lessonLevel, personaID: personaID,
            situationEn: result.situationEn, roleReversal: beats.first?.line.isEmpty ?? true, targetTerms: [],
            beats: beats, closingLine: closing.japanese, closingKana: closing.kana, closingEnglish: closing.english,
            placeEn: place.isEmpty ? nil : place, canDoEn: nil, missionsEn: nil, field: nil
        )
        let nameEn = result.partnerNameEn.trimmingCharacters(in: .whitespacesAndNewlines)
        let persona = Persona(
            id: personaID, nameJa: result.partnerNameJa,
            nameEn: nameEn.isEmpty ? (isMonologue ? "Audience" : "Colleague") : nameEn,
            role: result.partnerRole, roleJa: "", personality: "", speakingRate: 1, formality: .professional, style: "",
            voiceGender: VoiceGender(rawValue: result.partnerGender.lowercased())
        )
        return MySceneLesson(scenario: scenario, persona: persona, glossary: glossary)
    }

    /// The other person's line with the learner's name in it (or, without a name, without the placeholder).
    private static func named(_ line: SceneResult.Line, _ learnerName: String) -> SceneResult.Line {
        guard line.japanese.contains("{name}") || line.kana.contains("{name}") || line.english.contains("{name}") else {
            return line
        }
        let name = learnerName.trimmingCharacters(in: .whitespacesAndNewlines)
        func fill(_ text: String) -> String {
            guard name.isEmpty else { return text.replacingOccurrences(of: "{name}", with: name) }
            var result = text
            for placeholder in ["{name}さん、", "{name}さん", "{name}様", "{name}, ", ", {name}", "{name}"] {
                result = result.replacingOccurrences(of: placeholder, with: "")
            }
            return result.trimmingCharacters(in: .whitespaces)
        }
        let words = line.words.compactMap { word -> WordGloss? in
            guard word.ja == "{name}" else { return word }
            return name.isEmpty ? nil : WordGloss(ja: name, kana: name, en: word.en)
        }
        return SceneResult.Line(japanese: fill(line.japanese), kana: fill(line.kana), english: fill(line.english), words: words)
    }
}

public extension Scenario {
    /// No one else speaks: a speech or a self-introduction, said one sentence at a time.
    var isMonologue: Bool {
        !beats.isEmpty && beats.allSatisfy { $0.line.isEmpty } && closingLine.isEmpty
    }

    /// One of the learner's own scenes (My scenes).
    var isLearnersOwn: Bool { id.hasPrefix(MyScene.idPrefix) }
}

public extension ContentLibrary {
    /// The library with more scenes, their people and their words. Scenes and people with the same id replace
    /// those already there; the bundled word lists win over new ones for the same line.
    func adding(scenarios extra: [Scenario], personas extraPersonas: [Persona],
                glossary extraGlossary: [String: [WordGloss]]) -> ContentLibrary {
        let scenarioIDs = Set(extra.map(\.id))
        let personaIDs = Set(extraPersonas.map(\.id))
        return ContentLibrary(
            items: items, vocabulary: vocabulary, grammar: grammar,
            scenarios: scenarios.filter { !scenarioIDs.contains($0.id) } + extra,
            personas: personas.filter { !personaIDs.contains($0.id) } + extraPersonas, cues: cues,
            glossary: glossary.merging(extraGlossary) { bundled, _ in bundled }
        )
    }

    /// The library with the learner's own scenes in it, so every screen and session can use them.
    func including(_ scenes: [MyScene], learnerName: String) -> ContentLibrary {
        let lessons = scenes.map { $0.lesson(learnerName: learnerName) }
        var words: [String: [WordGloss]] = [:]
        for lesson in lessons { words.merge(lesson.glossary) { first, _ in first } }
        return adding(scenarios: lessons.map(\.scenario), personas: lessons.map(\.persona), glossary: words)
    }
}
