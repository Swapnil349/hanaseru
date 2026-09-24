import Foundation
import LearningCore
import SessionCore
import SwiftData

// SwiftData records. Every property has a default and nothing is `.unique`, so the store can move to
// CloudKit sync later without a schema rewrite (spec §58). No audio is ever stored (spec §29, §60).

@Model
final class LearnerProfileRecord {
    var name: String = ""
    var createdAt: Date = Date()
    var difficultyData: Data?

    init(name: String = "") {
        self.name = name
    }

    var difficulty: DifficultyProfile {
        get { difficultyData.flatMap { try? JSONDecoder().decode(DifficultyProfile.self, from: $0) } ?? .starting }
        set { difficultyData = try? JSONEncoder().encode(newValue) }
    }
}

@Model
final class KnowledgeRecord {
    var itemID: String = ""
    var stateData: Data = Data()
    var updatedAt: Date = Date()

    init(itemID: String, stateData: Data) {
        self.itemID = itemID
        self.stateData = stateData
    }

    var state: KnowledgeState? {
        try? JSONDecoder().decode(KnowledgeState.self, from: stateData)
    }
}

/// The personal error database (spec §30).
@Model
final class MistakeRecord {
    var key: String = ""
    var typeRaw: String = MistakeType.other.rawValue
    var correction: String = ""
    var explanation: String = ""
    /// Text of the learner's most recent utterance with this mistake. Cleared by "Delete voice data".
    var lastSaid: String = ""
    var itemID: String?
    var occurrences: Int = 0
    var firstSeen: Date = Date()
    var lastSeen: Date = Date()

    init(observation: MistakeObservation) {
        key = observation.aggregationKey
        typeRaw = observation.type.rawValue
        correction = observation.correction
        explanation = observation.explanation
        lastSaid = observation.said
        itemID = observation.itemID
        occurrences = 1
        firstSeen = observation.date
        lastSeen = observation.date
    }

    var type: MistakeType { MistakeType(rawValue: typeRaw) ?? .other }

    var summary: MistakeSummary {
        MistakeSummary(type: type, correction: correction, explanation: explanation, lastSaid: lastSaid,
                       itemID: itemID, occurrences: occurrences, lastSeen: lastSeen)
    }
}

@Model
final class SessionRecord {
    var startedAt: Date = Date()
    var endedAt: Date = Date()
    var plannedMinutes: Int = 0
    var focusRaw: String = SessionFocus.surprise.rawValue
    var secondsListening: Double = 0
    var secondsSpeaking: Double = 0
    var conversationTurns: Int = 0
    var exercisesCompleted: Int = 0
    var scenarioIDsJoined: String = ""
    var resultsData: Data = Data()
    var phraseJapanese: String = ""
    var phraseEnglish: String = ""
    var completedNormally: Bool = true

    init(summary: SessionSummary) {
        startedAt = summary.startedAt
        endedAt = summary.endedAt
        plannedMinutes = summary.plannedMinutes
        focusRaw = summary.focus.rawValue
        secondsListening = summary.secondsListening
        secondsSpeaking = summary.secondsSpeaking
        conversationTurns = summary.conversationTurns
        exercisesCompleted = summary.exercisesCompleted
        scenarioIDsJoined = summary.scenarioIDs.joined(separator: ",")
        resultsData = (try? JSONEncoder().encode(summary.results)) ?? Data()
        phraseJapanese = summary.phraseJapanese
        phraseEnglish = summary.phraseEnglish
        completedNormally = summary.completedNormally
    }

    var results: [ExerciseResult] {
        (try? JSONDecoder().decode([ExerciseResult].self, from: resultsData)) ?? []
    }

    var scenarioIDs: [String] {
        scenarioIDsJoined.split(separator: ",").map(String.init)
    }
}

enum PhraseSource: String, CaseIterable, Identifiable {
    case heard
    case used
    case struggled
    case wantToRemember

    var id: String { rawValue }

    var title: String {
        switch self {
        case .heard: "Heard at work"
        case .used: "I used this"
        case .struggled: "Struggled with"
        case .wantToRemember: "Want to remember"
        }
    }
}

/// A phrase in "My Japanese" (spec §15). Becomes a `LearningItem` that the planner prioritises.
@Model
final class PersonalPhraseRecord {
    var phraseID: String = UUID().uuidString
    var japanese: String = ""
    var kana: String = ""
    var english: String = ""
    var note: String = ""
    var sourceRaw: String = PhraseSource.heard.rawValue
    var trackRaw: String = Track.work.rawValue
    var createdAt: Date = Date()

    init(japanese: String, kana: String, english: String, note: String, source: PhraseSource, track: Track) {
        self.japanese = japanese
        self.kana = kana
        self.english = english
        self.note = note
        self.sourceRaw = source.rawValue
        self.trackRaw = track.rawValue
    }

    var source: PhraseSource { PhraseSource(rawValue: sourceRaw) ?? .heard }
    var track: Track { Track(rawValue: trackRaw) ?? .work }

    var learningItem: LearningItem {
        LearningItem(
            id: "p.\(phraseID)", japanese: japanese, kana: kana.isEmpty ? japanese : kana, english: english,
            track: track, category: "personal", level: 2, kind: .phrase, politeness: .professional,
            usageNote: note.isEmpty ? nil : note,
            promptEn: english.isEmpty ? nil : "Say: \(english)",
            acceptableResponses: [japanese], isPersonal: true
        )
    }
}

enum HanaseruSchema {
    static let models: [any PersistentModel.Type] = [
        LearnerProfileRecord.self, KnowledgeRecord.self, MistakeRecord.self, SessionRecord.self, PersonalPhraseRecord.self,
    ]
}
