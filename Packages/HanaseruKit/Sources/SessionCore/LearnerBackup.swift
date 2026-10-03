import Foundation
import LearningCore

/// Everything Hanaseru knows about the learner, as one JSON file kept outside the app (Files, iCloud Drive,
/// AirDrop). A free sideloaded install starts empty when it's reinstalled under a different Apple ID; a backup
/// brings the progress back. Secrets (the coach token) are never included.
public struct LearnerBackup: Codable, Equatable, Sendable {
    public static let formatName = "hanaseru-backup"
    public static let currentVersion = 1

    public var format: String
    public var version: Int
    public var exportedAt: Date
    public var profile: Profile
    public var knowledge: [Knowledge]
    public var mistakes: [Mistake]
    public var sessions: [Session]
    public var phrases: [Phrase]
    public var preferences: Preferences

    public init(exportedAt: Date, profile: Profile, knowledge: [Knowledge], mistakes: [Mistake], sessions: [Session],
                phrases: [Phrase], preferences: Preferences) {
        self.format = Self.formatName
        self.version = Self.currentVersion
        self.exportedAt = exportedAt
        self.profile = profile
        self.knowledge = knowledge
        self.mistakes = mistakes
        self.sessions = sessions
        self.phrases = phrases
        self.preferences = preferences
    }

    public struct Profile: Codable, Equatable, Sendable {
        public var name: String
        public var createdAt: Date
        public var difficulty: DifficultyProfile

        public init(name: String, createdAt: Date, difficulty: DifficultyProfile) {
            self.name = name
            self.createdAt = createdAt
            self.difficulty = difficulty
        }
    }

    /// Spaced-repetition state of one item or scene line.
    public struct Knowledge: Codable, Equatable, Sendable {
        public var itemID: String
        public var updatedAt: Date
        public var state: KnowledgeState

        public init(itemID: String, updatedAt: Date, state: KnowledgeState) {
            self.itemID = itemID
            self.updatedAt = updatedAt
            self.state = state
        }
    }

    public struct Mistake: Codable, Equatable, Sendable {
        public var key: String
        public var type: String
        public var correction: String
        public var explanation: String
        public var lastSaid: String
        public var itemID: String?
        public var occurrences: Int
        public var firstSeen: Date
        public var lastSeen: Date

        public init(key: String, type: String, correction: String, explanation: String, lastSaid: String,
                    itemID: String?, occurrences: Int, firstSeen: Date, lastSeen: Date) {
            self.key = key
            self.type = type
            self.correction = correction
            self.explanation = explanation
            self.lastSaid = lastSaid
            self.itemID = itemID
            self.occurrences = occurrences
            self.firstSeen = firstSeen
            self.lastSeen = lastSeen
        }
    }

    public struct Session: Codable, Equatable, Sendable {
        public var startedAt: Date
        public var endedAt: Date
        public var plannedMinutes: Int
        public var focus: String
        public var secondsListening: Double
        public var secondsSpeaking: Double
        public var conversationTurns: Int
        public var scenarioIDs: [String]
        public var results: [ExerciseResult]
        public var phraseJapanese: String
        public var phraseEnglish: String
        public var completedNormally: Bool

        public init(startedAt: Date, endedAt: Date, plannedMinutes: Int, focus: String, secondsListening: Double,
                    secondsSpeaking: Double, conversationTurns: Int, scenarioIDs: [String], results: [ExerciseResult],
                    phraseJapanese: String, phraseEnglish: String, completedNormally: Bool) {
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.plannedMinutes = plannedMinutes
            self.focus = focus
            self.secondsListening = secondsListening
            self.secondsSpeaking = secondsSpeaking
            self.conversationTurns = conversationTurns
            self.scenarioIDs = scenarioIDs
            self.results = results
            self.phraseJapanese = phraseJapanese
            self.phraseEnglish = phraseEnglish
            self.completedNormally = completedNormally
        }

        /// The session as the summary the app stores.
        public var summary: SessionSummary {
            SessionSummary(startedAt: startedAt, endedAt: endedAt, plannedMinutes: plannedMinutes,
                           focus: SessionFocus(rawValue: focus) ?? .surprise, secondsListening: secondsListening,
                           secondsSpeaking: secondsSpeaking, results: results, conversationTurns: conversationTurns,
                           scenarioIDs: scenarioIDs, mistakes: [], wentWell: [], toPractise: [], phraseID: nil,
                           phraseJapanese: phraseJapanese, phraseEnglish: phraseEnglish,
                           completedNormally: completedNormally)
        }
    }

    /// A phrase from "My Japanese".
    public struct Phrase: Codable, Equatable, Sendable {
        public var phraseID: String
        public var japanese: String
        public var kana: String
        public var english: String
        public var note: String
        public var source: String
        public var track: String
        public var createdAt: Date

        public init(phraseID: String, japanese: String, kana: String, english: String, note: String, source: String,
                    track: String, createdAt: Date) {
            self.phraseID = phraseID
            self.japanese = japanese
            self.kana = kana
            self.english = english
            self.note = note
            self.source = source
            self.track = track
            self.createdAt = createdAt
        }
    }

    /// App settings worth carrying over. Every field is optional, so older and newer backups both load.
    public struct Preferences: Codable, Equatable, Sendable {
        public var kanjiIntensity: String?
        public var showRomaji: Bool?
        public var showEnglish: Bool?
        public var englishVoice: String?
        public var coachServerURL: String?
        public var helpOnboardingDone: Bool?

        public init(kanjiIntensity: String? = nil, showRomaji: Bool? = nil, showEnglish: Bool? = nil,
                    englishVoice: String? = nil, coachServerURL: String? = nil, helpOnboardingDone: Bool? = nil) {
            self.kanjiIntensity = kanjiIntensity
            self.showRomaji = showRomaji
            self.showEnglish = showEnglish
            self.englishVoice = englishVoice
            self.coachServerURL = coachServerURL
            self.helpOnboardingDone = helpOnboardingDone
        }
    }

    public enum ReadError: Error, Equatable, LocalizedError {
        case notABackup
        case newerVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .notABackup: "This file isn't a Hanaseru backup."
            case .newerVersion(let version): "This backup was made by a newer Hanaseru (format \(version)). Update the app first."
            }
        }
    }

    // MARK: - File

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> LearnerBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        struct Header: Decodable {
            var format: String?
            var version: Int?
        }
        guard let header = try? decoder.decode(Header.self, from: data), header.format == formatName else {
            throw ReadError.notABackup
        }
        if let version = header.version, version > currentVersion { throw ReadError.newerVersion(version) }
        return try decoder.decode(LearnerBackup.self, from: data)
    }

    /// "Hanaseru backup 2026-10-03.json"
    public static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "Hanaseru backup \(formatter.string(from: date)).json"
    }

    /// One line for a confirmation dialog: "3 Oct 2026 · 12 sessions · 85 lines practised · 4 phrases".
    public var overview: String {
        func count(_ number: Int, _ noun: String) -> String { "\(number) \(noun)\(number == 1 ? "" : "s")" }
        let date = exportedAt.formatted(date: .abbreviated, time: .omitted)
        return "\(date) · \(count(sessions.count, "session")) · \(count(knowledge.count, "line")) practised · "
            + count(phrases.count, "phrase")
    }
}
