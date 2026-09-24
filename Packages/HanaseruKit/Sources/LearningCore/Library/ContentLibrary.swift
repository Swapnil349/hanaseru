import Foundation

public enum ContentError: Error, CustomStringConvertible {
    case missingResource(String)
    case invalid(String, underlying: Error)

    public var description: String {
        switch self {
        case .missingResource(let name): "Missing content file \(name).json"
        case .invalid(let name, let error): "Invalid content in \(name).json: \(error)"
        }
    }
}

/// All learning content, loaded from JSON (spec §57). Nothing here is hard-coded in views.
public struct ContentLibrary: Sendable {
    public private(set) var items: [LearningItem]
    public let vocabulary: [VocabularyTerm]
    public let grammar: [GrammarPattern]
    public let scenarios: [Scenario]
    public let personas: [Persona]
    public let cues: [CueKey: CoachCue]

    private var itemIndex: [String: Int]

    public init(items: [LearningItem], vocabulary: [VocabularyTerm] = [], grammar: [GrammarPattern] = [],
                scenarios: [Scenario] = [], personas: [Persona] = [], cues: [CueKey: CoachCue] = [:]) {
        self.items = items
        self.vocabulary = vocabulary
        self.grammar = grammar
        self.scenarios = scenarios
        self.personas = personas
        self.cues = cues
        self.itemIndex = Dictionary(items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Loads the content bundled with the package.
    public static func bundled() throws -> ContentLibrary {
        try load(from: .module)
    }

    public static func load(from bundle: Bundle) throws -> ContentLibrary {
        func decode<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
            guard let url = bundle.url(forResource: name, withExtension: "json") else {
                throw ContentError.missingResource(name)
            }
            do {
                return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
            } catch {
                throw ContentError.invalid(name, underlying: error)
            }
        }
        let rawCues = try decode("cues", as: [String: CoachCue].self)
        let cues = Dictionary(uniqueKeysWithValues: rawCues.compactMap { key, cue in
            CueKey(rawValue: key).map { ($0, cue) }
        })
        return ContentLibrary(
            items: try decode("phrases", as: [LearningItem].self),
            vocabulary: try decode("vocabulary", as: [VocabularyTerm].self),
            grammar: try decode("grammar", as: [GrammarPattern].self),
            scenarios: try decode("scenarios", as: [Scenario].self),
            personas: try decode("personas", as: [Persona].self),
            cues: cues
        )
    }

    public func item(id: String) -> LearningItem? {
        itemIndex[id].map { items[$0] }
    }

    public func scenario(id: String) -> Scenario? {
        scenarios.first { $0.id == id }
    }

    public func persona(id: String) -> Persona? {
        personas.first { $0.id == id }
    }

    public func term(id: String) -> VocabularyTerm? {
        vocabulary.first { $0.id == id }
    }

    public func cue(_ key: CueKey) -> CoachCue {
        cues[key] ?? CoachCue(ja: "", kana: "", en: key.rawValue)
    }

    /// Returns a library that also contains the learner's personal phrases (spec §15).
    /// Personal items replace bundled items with the same id.
    public func merging(personal: [LearningItem]) -> ContentLibrary {
        let personalIDs = Set(personal.map(\.id))
        return ContentLibrary(
            items: items.filter { !personalIDs.contains($0.id) } + personal,
            vocabulary: vocabulary, grammar: grammar, scenarios: scenarios, personas: personas, cues: cues
        )
    }
}
