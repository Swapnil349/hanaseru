import Foundation
import Testing
import LearningCore
@testable import SessionCore

@Suite("Backup file")
struct BackupTests {
    /// Whole-second dates: the file stores ISO 8601 times.
    let day = Date(timeIntervalSince1970: 1_790_000_000)

    func sample() -> LearnerBackup {
        LearnerBackup(
            exportedAt: day,
            profile: .init(name: "Swapnil", createdAt: day, difficulty: .starting),
            knowledge: [.init(itemID: "w.otsukare", updatedAt: day, state: KnowledgeState(itemID: "w.otsukare", introducedAt: day))],
            mistakes: [.init(key: "pastTense|〜ました", type: "pastTense", correction: "〜ました", explanation: "Use the past.",
                             lastSaid: "昨日行きます", itemID: "e.past.tokyo", occurrences: 2, firstSeen: day, lastSeen: day)],
            sessions: [.init(startedAt: day, endedAt: day.addingTimeInterval(300), plannedMinutes: 5, focus: "work",
                             secondsListening: 120, secondsSpeaking: 40, conversationTurns: 3, scenarioIDs: ["s.site.pier"],
                             results: [ExerciseResult(kind: .recall, itemID: "w.otsukare", verdict: .natural, latency: 1.5,
                                                      date: day, lineID: "w.otsukare", level: 2, outcome: .cleanFast)],
                             phraseJapanese: "お疲れさまです。", phraseEnglish: "Hi.", completedNormally: true)],
            phrases: [.init(phraseID: "abc", japanese: "工程に遅れが出ています。", kana: "こうていにおくれがでています。",
                            english: "The schedule is slipping.", note: "", source: "heard", track: "work", createdAt: day)],
            preferences: .init(kanjiIntensity: "minimal", showEnglish: true, helpOnboardingDone: true)
        )
    }

    @Test func everythingSurvivesTheFile() throws {
        let backup = sample()
        let restored = try LearnerBackup.decode(backup.encoded())
        #expect(restored == backup)
        #expect(restored.sessions.first?.summary.focus == .work)
        #expect(restored.sessions.first?.summary.exercisesCompleted == 1)
        #expect(restored.overview.hasSuffix("1 session · 1 line practised · 1 phrase"))
    }

    @Test func otherFilesAreRefused() {
        #expect(throws: LearnerBackup.ReadError.notABackup) {
            try LearnerBackup.decode(Data(#"{"hello": 1}"#.utf8))
        }
        #expect(throws: LearnerBackup.ReadError.notABackup) {
            try LearnerBackup.decode(Data("not json".utf8))
        }
        #expect(throws: LearnerBackup.ReadError.newerVersion(2)) {
            try LearnerBackup.decode(Data(#"{"format": "hanaseru-backup", "version": 2}"#.utf8))
        }
    }

    @Test func aSparseBackupStillLoads() throws {
        let json = """
        {"format": "hanaseru-backup", "version": 1, "exportedAt": "2026-10-03T09:00:00Z",
         "profile": {"name": "", "createdAt": "2026-10-03T09:00:00Z", "difficulty": {"level": 3}},
         "knowledge": [], "mistakes": [], "sessions": [], "phrases": [], "preferences": {}}
        """
        let backup = try LearnerBackup.decode(Data(json.utf8))
        #expect(backup.profile.difficulty.level == 3)
        #expect(backup.profile.difficulty.englishSupport == DifficultyProfile.starting.englishSupport)
        #expect(backup.preferences == LearnerBackup.Preferences())
    }

    @Test func fileNameSaysWhatItIs() {
        let name = LearnerBackup.fileName(for: day)
        #expect(name.hasPrefix("Hanaseru backup 2026-09-"))
        #expect(name.hasSuffix(".json"))
    }
}
