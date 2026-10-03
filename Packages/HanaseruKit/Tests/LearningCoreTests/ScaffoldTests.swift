import Foundation
import Testing
@testable import LearningCore

@Suite("Scaffold levels, timing and teaching content")
struct ScaffoldTests {
    let library = try! ContentLibrary.bundled()

    @Test func timingFollowsTheLevelTable() {
        let profile = DifficultyProfile.starting // responseWindow 10 → windowScale 1.0
        let guided = TurnTiming.make(level: .guided, chunkCount: 3, profile: profile)
        #expect(guided.window == 8.0)
        #expect(guided.nudgeAt == 4.0)
        #expect(guided.afterNudge == 5.5)
        let cued = TurnTiming.make(level: .cued, chunkCount: 4, profile: profile)
        #expect(abs(cued.window - 7.4) < 0.0001)       // +0.4 s for the 4th chunk
        #expect(abs(cued.nudgeAt - 3.7) < 0.0001)
        #expect(abs(cued.afterNudge - 5.2) < 0.0001)
        let fluent = TurnTiming.make(level: .fluent, chunkCount: 1, profile: profile)
        #expect(fluent.window == 3.5)
        #expect(fluent.afterNudge == 3.25)
    }

    @Test func windowsScaleWithTheProfile() {
        var slow = DifficultyProfile.starting
        slow.responseWindow = 14
        #expect(TurnTiming.make(level: .cued, chunkCount: 2, profile: slow).window > 7)
        var fast = DifficultyProfile.starting
        fast.responseWindow = 5
        #expect(abs(TurnTiming.make(level: .cued, chunkCount: 2, profile: fast).window - 4.9) < 0.0001) // clamped 0.7×
    }

    @Test func outcomesGradeSpacedRepetition() {
        #expect(ReviewGrade(outcome: .cleanFast, level: .cued, onset: 1) == .easy)
        #expect(ReviewGrade(outcome: .clean, level: .cued, onset: 3) == .good)
        #expect(ReviewGrade(outcome: .clean, level: .guided, onset: 3) == .hard)
        #expect(ReviewGrade(outcome: .clean, level: .cued, onset: 7) == .hard)
        #expect(ReviewGrade(outcome: .hinted, level: .cued, onset: 2) == .hard)
        #expect(ReviewGrade(outcome: .modelNeeded, level: .cued, onset: nil) == .again)
        #expect(ReviewGrade(outcome: .unclear, level: .cued, onset: nil) == nil)
        #expect(ReviewGrade(outcome: .skipped, level: .cued, onset: nil) == nil)
    }

    @Test func entryLevelComesFromHistory() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let scheduler = ReviewScheduler()
        #expect(ScaffoldLevel.entry(from: nil) == nil)
        let fresh = KnowledgeState(itemID: "x", introducedAt: start)
        #expect(ScaffoldLevel.entry(from: fresh) == nil)
        #expect(ScaffoldLevel.entry(from: scheduler.record(fresh, dimension: .spokenRecall, grade: .again, at: start)) == .guided)
        #expect(ScaffoldLevel.entry(from: scheduler.record(fresh, dimension: .spokenRecall, grade: .hard, at: start)) == .cued)
        #expect(ScaffoldLevel.entry(from: scheduler.record(fresh, dimension: .spokenRecall, grade: .good, at: start)) == .intent)
    }

    @Test func outcomesMapToLegacyVerdicts() {
        #expect(TurnOutcome.cleanFast.legacyVerdict.isSuccess)
        #expect(TurnOutcome.clean.legacyVerdict.isSuccess)
        #expect(!TurnOutcome.hinted.legacyVerdict.isSuccess)
        #expect(TurnOutcome.modelNeeded.severity < TurnOutcome.hinted.severity)
    }

    @Test func sceneLinesAreTaughtWithEnglish() throws {
        let scenario = try #require(library.scenario(id: "s.site.pier"))
        let lines = library.lines(in: scenario, learnerName: "Swapnil")
        #expect(lines.count == scenario.beats.count)
        for line in lines {
            #expect(line.id.hasPrefix("s.site.pier#"))
            #expect(!line.english.isEmpty, "\(line.id) has no English")
            #expect(!line.kana.isEmpty, "\(line.id) has no kana")
            #expect(!line.chunks.isEmpty)
            #expect(line.cueEn.hasPrefix("Say: ") || line.cueEn.hasPrefix("Ask: ") || !line.cueEn.isEmpty)
            #expect(line.partner != nil)
        }
    }

    @Test func selfIntroductionIsPersonalised() throws {
        let scenario = try #require(library.scenario(id: "s.first.meeting"))
        let first = try #require(library.practiceLine(scenario: scenario, beatIndex: 0, learnerName: "Swapnil"))
        #expect(first.japanese.contains("Swapnil"))
        #expect(!first.japanese.contains("{name}"))
        #expect(first.partner == nil) // the learner starts this scene
    }

    @Test func questionsAreCuedWithAsk() {
        let line = PracticeLine.defaultCue(english: "Is there any problem?", japanese: "何か問題はありますか？")
        #expect(line == "Ask: Is there any problem?")
        #expect(PracticeLine.defaultCue(english: "It's fine.", japanese: "大丈夫です。") == "Say: It's fine.")
    }

    @Test func chunksDecodeFromStringsOrObjects() throws {
        let json = #"[{"ja": "特に", "kana": "とくに"}, "ありません。"]"#
        let chunks = try JSONDecoder().decode([Chunk].self, from: Data(json.utf8))
        #expect(chunks == [Chunk(ja: "特に", kana: "とくに"), Chunk(ja: "ありません。", kana: "ありません。")])
    }

    @Test func modelLinesDecodeLegacyStrings() throws {
        let json = #"["はい、しました。", {"japanese": "特にありません。", "kana": "とくにありません。", "english": "Nothing in particular."}]"#
        let lines = try JSONDecoder().decode([ModelLine].self, from: Data(json.utf8))
        #expect(lines[0].japanese == "はい、しました。")
        #expect(lines[0].english.isEmpty)
        #expect(lines[1].english == "Nothing in particular.")
    }

    @Test func profilesDecodeEvenWhenPartlyWritten() throws {
        let full = #"{"level":2,"englishSupport":0.8,"speechRate":0.85,"responseWindow":10}"#
        #expect(try JSONDecoder().decode(DifficultyProfile.self, from: Data(full.utf8)) == .starting)
        let partial = try JSONDecoder().decode(DifficultyProfile.self, from: Data(#"{"level":3}"#.utf8))
        #expect(partial.level == 3)
        #expect(partial.englishSupport == DifficultyProfile.starting.englishSupport)
        #expect(partial.responseWindow == DifficultyProfile.starting.responseWindow)
    }

    @Test func oldExerciseResultsStillDecode() throws {
        let json = #"[{"kind":"recall","itemID":"w.confirm.will","verdict":"natural","latency":1.5,"date":0}]"#
        let results = try JSONDecoder().decode([ExerciseResult].self, from: Data(json.utf8))
        #expect(results.first?.outcome == nil)
        #expect(results.first?.isSuccess == true)
    }

    @Test func coachLanguageFollowsEnglishSupport() {
        var profile = DifficultyProfile.starting
        #expect(profile.coachLanguage == .english)
        profile.englishSupport = 0.4
        #expect(profile.coachLanguage == .bilingual)
        profile.englishSupport = 0.1
        #expect(profile.coachLanguage == .japanese)
    }

    @Test func everyTaughtLineHasEnglishAndKana() {
        for scenario in library.scenarios {
            for (index, beat) in scenario.beats.enumerated() {
                for response in beat.responses {
                    #expect(!response.english.isEmpty, "\(scenario.id) beat \(index): 「\(response.japanese)」 has no English")
                    #expect(!response.kana.isEmpty, "\(scenario.id) beat \(index): 「\(response.japanese)」 has no kana")
                }
            }
        }
        for item in library.items {
            if let check = item.listening {
                #expect(!check.modelAnswerEn.isEmpty, "\(item.id) listening answer has no English")
            }
        }
    }
}
