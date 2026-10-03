import Foundation
import LearningCore
import SessionCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Backup and restore of everything in the learning database (see `LearnerBackup`).
extension SwiftDataLearnerRepository {
    func makeBackup(now: Date = Date()) -> LearnerBackup {
        let profile = profile()
        let knowledge = fetchAll(KnowledgeRecord.self).compactMap { record -> LearnerBackup.Knowledge? in
            guard let state = record.state else { return nil }
            return LearnerBackup.Knowledge(itemID: record.itemID, updatedAt: record.updatedAt, state: state)
        }
        let mistakes = fetchAll(MistakeRecord.self).map { record in
            LearnerBackup.Mistake(key: record.key, type: record.typeRaw, correction: record.correction,
                                  explanation: record.explanation, lastSaid: record.lastSaid, itemID: record.itemID,
                                  occurrences: record.occurrences, firstSeen: record.firstSeen, lastSeen: record.lastSeen)
        }
        let sessions = fetchAll(SessionRecord.self).sorted { $0.startedAt < $1.startedAt }.map { record in
            LearnerBackup.Session(startedAt: record.startedAt, endedAt: record.endedAt, plannedMinutes: record.plannedMinutes,
                                  focus: record.focusRaw, secondsListening: record.secondsListening,
                                  secondsSpeaking: record.secondsSpeaking, conversationTurns: record.conversationTurns,
                                  scenarioIDs: record.scenarioIDs, results: record.results,
                                  phraseJapanese: record.phraseJapanese, phraseEnglish: record.phraseEnglish,
                                  completedNormally: record.completedNormally)
        }
        let phrases = fetchAll(PersonalPhraseRecord.self).sorted { $0.createdAt < $1.createdAt }.map { record in
            LearnerBackup.Phrase(phraseID: record.phraseID, japanese: record.japanese, kana: record.kana,
                                 english: record.english, note: record.note, source: record.sourceRaw,
                                 track: record.trackRaw, createdAt: record.createdAt)
        }
        return LearnerBackup(
            exportedAt: now,
            profile: LearnerBackup.Profile(name: profile.name, createdAt: profile.createdAt, difficulty: profile.difficulty),
            knowledge: knowledge, mistakes: mistakes, sessions: sessions, phrases: phrases,
            preferences: .current()
        )
    }

    /// Replaces all learning data with the backup's.
    func restore(_ backup: LearnerBackup) {
        deleteEverything()
        let profile = LearnerProfileRecord(name: backup.profile.name)
        profile.createdAt = backup.profile.createdAt
        profile.difficulty = backup.profile.difficulty
        context.insert(profile)

        let encoder = JSONEncoder()
        for entry in backup.knowledge {
            guard let data = try? encoder.encode(entry.state) else { continue }
            let record = KnowledgeRecord(itemID: entry.itemID, stateData: data)
            record.updatedAt = entry.updatedAt
            context.insert(record)
        }
        for entry in backup.mistakes {
            let observation = MistakeObservation(type: MistakeType(rawValue: entry.type) ?? .other, itemID: entry.itemID,
                                                 said: entry.lastSaid, correction: entry.correction,
                                                 explanation: entry.explanation, date: entry.lastSeen)
            let record = MistakeRecord(observation: observation)
            record.key = entry.key
            record.occurrences = entry.occurrences
            record.firstSeen = entry.firstSeen
            context.insert(record)
        }
        for entry in backup.sessions {
            context.insert(SessionRecord(summary: entry.summary))
        }
        for entry in backup.phrases {
            let record = PersonalPhraseRecord(japanese: entry.japanese, kana: entry.kana, english: entry.english,
                                              note: entry.note, source: PhraseSource(rawValue: entry.source) ?? .heard,
                                              track: Track(rawValue: entry.track) ?? .work)
            record.phraseID = entry.phraseID
            record.createdAt = entry.createdAt
            context.insert(record)
        }
        persist()
        backup.preferences.apply()
    }

    private func fetchAll<Record: PersistentModel>(_ type: Record.Type) -> [Record] {
        (try? context.fetch(FetchDescriptor<Record>())) ?? []
    }
}

extension LearnerBackup.Preferences {
    /// The settings as they are now. The coach token stays in the Keychain and is never exported.
    static func current(_ defaults: UserDefaults = .standard) -> LearnerBackup.Preferences {
        LearnerBackup.Preferences(
            kanjiIntensity: defaults.string(forKey: SettingsKey.kanjiIntensity),
            showRomaji: defaults.object(forKey: SettingsKey.showRomaji) as? Bool,
            showEnglish: defaults.object(forKey: SettingsKey.showEnglish) as? Bool,
            englishVoice: defaults.string(forKey: SettingsKey.englishVoice),
            coachServerURL: defaults.string(forKey: SettingsKey.coachServerURL),
            helpOnboardingDone: defaults.object(forKey: SettingsKey.helpOnboardingDone) as? Bool
        )
    }

    func apply(_ defaults: UserDefaults = .standard) {
        if let kanjiIntensity { defaults.set(kanjiIntensity, forKey: SettingsKey.kanjiIntensity) }
        if let showRomaji { defaults.set(showRomaji, forKey: SettingsKey.showRomaji) }
        if let showEnglish { defaults.set(showEnglish, forKey: SettingsKey.showEnglish) }
        if let englishVoice { defaults.set(englishVoice, forKey: SettingsKey.englishVoice) }
        if let coachServerURL { defaults.set(coachServerURL, forKey: SettingsKey.coachServerURL) }
        if let helpOnboardingDone { defaults.set(helpOnboardingDone, forKey: SettingsKey.helpOnboardingDone) }
        defaults.set(true, forKey: SettingsKey.onboardingDone)
    }
}

/// The backup as a file for the system "Save to Files" sheet.
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// When this install stops opening. A free Apple ID signs sideloaded apps for 7 days; the date is in the
/// provisioning profile that Sideloadly embeds in the app. Nil in the Simulator and for App Store builds.
enum InstallInfo {
    static let expiresAt: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let plist = data.subdata(in: start.lowerBound..<end.upperBound)
        let profile = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
        return profile?["ExpirationDate"] as? Date
    }()

    /// Whole days left before the install expires (0 on the last day).
    static func daysLeft(now: Date = Date()) -> Int? {
        guard let expiresAt else { return nil }
        return max(0, Calendar.current.dateComponents([.day], from: now, to: expiresAt).day ?? 0)
    }

    /// "Fri 10 Oct, 14:05"
    static var expiryText: String? {
        expiresAt?.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}
