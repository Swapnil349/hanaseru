import Foundation
import LearningCore

/// One part of a script: a scene, a phrase or a listening check, with every line in order.
public struct ScriptPart: Identifiable, Equatable, Sendable {
    /// The part's place in the session (0 for a scene on its own).
    public var index: Int
    public var title: String
    /// The situation in English, when there is one.
    public var situation: String
    public var entries: [ScriptEntry]

    public var id: Int { index }

    public init(index: Int, title: String, situation: String = "", entries: [ScriptEntry]) {
        self.index = index
        self.title = title
        self.situation = situation
        self.entries = entries
    }
}

/// One line of a script, with its reading, its meaning and what its speaker button plays.
public struct ScriptEntry: Identifiable, Equatable, Sendable {
    public enum Speaker: Equatable, Sendable {
        /// The other person, by name.
        case partner(String)
        /// The learner's own line.
        case learner
        /// The sentence or question of a listening check.
        case narrator
    }

    public var id: String
    public var speaker: Speaker
    public var japanese: String
    public var kana: String
    /// In English letters.
    public var romaji: String
    public var english: String
    public var audio: [SpeechRequest]
    /// The practice line it belongs to, to show where the session is.
    public var lineID: String?
    /// The learner's lines in a scene: the line's place in the scene, to practise from there.
    public var startLine: Int?

    public init(id: String, speaker: Speaker, japanese: String, kana: String, romaji: String? = nil, english: String,
                audio: [SpeechRequest], lineID: String? = nil, startLine: Int? = nil) {
        self.id = id
        self.speaker = speaker
        self.japanese = japanese
        self.kana = kana
        self.romaji = romaji ?? Romaji.of(japanese, kana: kana)
        self.english = english
        self.audio = audio
        self.lineID = lineID
        self.startLine = startLine
    }

    public var isLearner: Bool { speaker == .learner }
}

public extension ScriptPart {
    /// The whole script as text in three ways — Japanese (with its kana), English letters and English — to
    /// share, print or keep.
    static func text(of parts: [ScriptPart]) -> String {
        var blocks: [String] = []
        for part in parts {
            var block = [part.title]
            if !part.situation.isEmpty { block.append(part.situation) }
            for entry in part.entries {
                let speaker: String = switch entry.speaker {
                case .partner(let name): name.isEmpty ? "Colleague" : name
                case .learner: "You"
                case .narrator: "Listen"
                }
                var lines = ["", speaker + ":", "  " + entry.japanese]
                if !entry.kana.isEmpty && entry.kana != entry.japanese { lines.append("  " + entry.kana) }
                if !entry.romaji.isEmpty { lines.append("  " + entry.romaji) }
                if !entry.english.isEmpty { lines.append("  " + entry.english) }
                block.append(contentsOf: lines)
            }
            blocks.append(block.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n\n") + "\n"
    }
}

public extension ContentLibrary {
    /// A scene's complete script: each line of the other person and the learner's answer, then the closing line.
    /// The learner's lines in `startable` can be practised from (all of them by default).
    func script(of scenario: Scenario, learnerName: String, index: Int = 0, startable: Range<Int>? = nil) -> ScriptPart {
        let name = persona(id: scenario.personaID)?.nameEn ?? ""
        var entries: [ScriptEntry] = []
        for (position, line) in lines(in: scenario, learnerName: learnerName).enumerated() {
            if let partner = line.partner {
                entries.append(ScriptEntry(id: "\(index)|p|\(line.id)", speaker: .partner(partner.nameEn.isEmpty ? name : partner.nameEn),
                                           japanese: partner.japanese, kana: partner.kana, english: partner.english,
                                           audio: [.partner(partner.japanese, gender: partner.gender)], lineID: line.id))
            }
            let canStart = startable.map { $0.contains(position) } ?? true
            entries.append(ScriptEntry(id: "\(index)|\(line.id)", speaker: .learner, japanese: line.japanese, kana: line.kana,
                                       romaji: line.romaji, english: line.english, audio: [.model(line.japanese)],
                                       lineID: line.id, startLine: canStart ? position : nil))
        }
        if !scenario.closingLine.isEmpty {
            let gender = persona(id: scenario.personaID)?.voiceGender
            entries.append(ScriptEntry(id: "\(index)|closing", speaker: .partner(name), japanese: scenario.closingLine,
                                       kana: scenario.closingKana, english: scenario.closingEnglish,
                                       audio: [.partner(scenario.closingLine, gender: gender)]))
        }
        return ScriptPart(index: index, title: scenario.title, situation: scenario.situationEn, entries: entries)
    }
}

public extension SessionRunner {
    /// The whole session as a script: every part's lines in order, to read, hear and learn by heart.
    func script() -> [ScriptPart] {
        plan.exercises.indices.compactMap { scriptPart($0) }
    }
}

extension SessionRunner {
    func scriptPart(_ index: Int) -> ScriptPart? {
        let exercise = plan.exercises[index]
        switch exercise {
        case .conversation(let id, let turns):
            guard let scenario = library.scenario(id: id) else { return nil }
            let count = library.lines(in: scenario, learnerName: learner.name).count
            guard count > 0 else { return nil }
            // The lines this session practises, as in `runConversation`.
            let start = min(max(0, options.sceneStartBeat), count - 1)
            return library.script(of: scenario, learnerName: learner.name, index: index,
                                  startable: start..<min(count, start + max(1, turns)))
        case .recall(let id), .shadowing(let id):
            guard let item = library.item(id: id) else { return nil }
            let line = library.practiceLine(item: item)
            var entries: [ScriptEntry] = []
            if let partner = line.partner {
                entries.append(ScriptEntry(id: "\(index)|p|\(line.id)", speaker: .partner(partner.nameEn),
                                           japanese: partner.japanese, kana: partner.kana, english: partner.english,
                                           audio: [.partner(partner.japanese, gender: partner.gender)], lineID: line.id))
            }
            entries.append(ScriptEntry(id: "\(index)|\(line.id)", speaker: .learner, japanese: line.japanese, kana: line.kana,
                                       romaji: line.romaji, english: line.english, audio: [.model(line.japanese)],
                                       lineID: line.id))
            return ScriptPart(index: index, title: title(for: exercise), situation: line.situationEn ?? "", entries: entries)
        case .listening(let id):
            guard let item = library.item(id: id) else { return nil }
            let gender = library.practiceLine(item: item).partner?.gender
            var entries = [ScriptEntry(id: "\(index)|\(item.id)", speaker: .narrator, japanese: item.japanese, kana: item.kana,
                                       romaji: item.romaji.isEmpty ? nil : item.romaji, english: item.english,
                                       audio: [.partner(item.japanese, gender: gender)], lineID: item.id)]
            if let check = item.listening {
                entries.append(ScriptEntry(id: "\(index)|q", speaker: .narrator, japanese: check.questionJa, kana: "",
                                           english: check.questionEn, audio: [.model(check.questionJa)], lineID: item.id))
                entries.append(ScriptEntry(id: "\(index)|a", speaker: .learner, japanese: check.modelAnswer,
                                           kana: check.modelAnswerKana, english: check.modelAnswerEn,
                                           audio: [.model(check.modelAnswer)]))
            }
            return ScriptPart(index: index, title: title(for: exercise), entries: entries)
        }
    }
}
