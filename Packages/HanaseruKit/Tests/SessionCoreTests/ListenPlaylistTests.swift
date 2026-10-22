import Foundation
import Testing
import LearningCore
@testable import SessionCore

@Suite("Listen: a playlist of scenes to hear hands-free")
struct ListenPlaylistTests {
    static let speech = MyScene(
        id: "my.speech", kind: .monologue, description: "Introduce myself at the morning meeting",
        createdAt: 1_760_000_000_000, updatedAt: 1_760_000_000_000,
        result: SceneResult(
            title: "Introducing myself", titleJa: "自己紹介", situationEn: "The morning meeting.",
            beats: [
                SceneResult.Beat(learner: SceneResult.Line(japanese: "おはようございます。", kana: "おはようございます。",
                                                           english: "Good morning."),
                                 hintEn: "Greet everyone"),
                SceneResult.Beat(learner: SceneResult.Line(japanese: "{name}です。", kana: "{name}です。",
                                                           english: "I'm {name}."),
                                 hintEn: "Say your name"),
                SceneResult.Beat(learner: SceneResult.Line(japanese: "インドから来ました。", kana: "いんどからきました。",
                                                           english: "I'm from India."),
                                 hintEn: "Say where you're from"),
            ]
        )
    )

    static let chat = MyScene(
        id: "my.chat", kind: .conversation, description: "Lunch with a colleague",
        createdAt: 1_760_000_000_000, updatedAt: 1_760_000_000_000,
        result: SceneResult(
            title: "Lunch", titleJa: "昼ご飯", situationEn: "At the canteen.", partnerNameEn: "Sato",
            partnerGender: "male",
            beats: [
                SceneResult.Beat(partner: SceneResult.Line(japanese: "{name}さん、お昼どうですか。", kana: "",
                                                           english: "{name}, how about lunch?"),
                                 learner: SceneResult.Line(japanese: "はい、行きましょう。", kana: "はい、いきましょう。",
                                                           english: "Yes, let's go."),
                                 hintEn: "Say yes"),
                // The learner starts this exchange: nothing from the partner.
                SceneResult.Beat(learner: SceneResult.Line(japanese: "何にしますか。", kana: "なににしますか。",
                                                           english: "What will you have?"),
                                 hintEn: "Ask what they'll have"),
            ],
            closing: SceneResult.Line(japanese: "じゃあ、行きましょう。", kana: "じゃあ、いきましょう。", english: "Well, let's go.")
        )
    )

    func bundled() throws -> ContentLibrary {
        try ContentLibrary.bundled()
    }

    func texts(_ playlist: ListenPlaylist) -> [String] {
        playlist.scenes.flatMap { $0.utterances.map(\.request.text) } + playlist.ending.map(\.request.text)
    }

    func requests(_ playlist: ListenPlaylist) -> [SpeechRequest] {
        playlist.scenes.flatMap { $0.utterances.map(\.request) } + playlist.ending.map(\.request)
    }

    /// A library of `count` copies of one bundled scene, each with `beats` copies of its first beat.
    func copiesLibrary(copies count: Int, beats: Int) throws -> ContentLibrary {
        let bundled = try bundled()
        let base = try #require(bundled.scenarios.first { $0.workField == nil && !$0.beats.isEmpty })
        let scenarios = (0..<count).map { index -> Scenario in
            var scenario = base
            scenario.id = "copy\(index)"
            scenario.beats = Array(repeating: base.beats[0], count: beats)
            return scenario
        }
        return ContentLibrary(items: [], scenarios: scenarios, personas: bundled.personas)
    }

    // MARK: - Length

    @Test(arguments: [ListenLength.five, .ten], [ListenLanguage.japaneseOnly, .withEnglish])
    func fillsTheChosenTime(length: ListenLength, language: ListenLanguage) throws {
        let library = try bundled()
        for seed: UInt64 in [1, 2, 3, 42, 2026] {
            let choices = ListenPlaylist.Choices(language: language, length: length, source: .everything)
            let playlist = ListenPlaylist.make(library: library, field: .engineering, choices: choices, learnerName: "Swapnil",
                                               recentlyPlayed: [], seed: seed)
            #expect((ListenPlaylist.minimumScenes...ListenPlaylist.maximumScenes).contains(playlist.scenes.count))
            let scenesTime = playlist.scenes.reduce(0) { $0 + $1.estimatedDuration }
            #expect(scenesTime >= length.targetDuration || playlist.scenes.count == ListenPlaylist.maximumScenes,
                    "\(length) \(language) seed \(seed): \(scenesTime) s in \(playlist.scenes.count) scenes")
            // No more scenes than needed: without the last one it would have been too short.
            if playlist.scenes.count > ListenPlaylist.minimumScenes {
                let withoutLast = scenesTime - (playlist.scenes.last?.estimatedDuration ?? 0)
                #expect(withoutLast < length.targetDuration)
            }
            #expect(Set(playlist.scenes.map(\.id)).count == playlist.scenes.count)
        }
    }

    @Test func tenMinutesHoldMoreThanFive() throws {
        let library = try bundled()
        let short = ListenPlaylist.make(library: library, field: .engineering,
                                        choices: .init(length: .five), learnerName: "", recentlyPlayed: [], seed: 7)
        let long = ListenPlaylist.make(library: library, field: .engineering,
                                       choices: .init(length: .ten), learnerName: "", recentlyPlayed: [], seed: 7)
        #expect(long.scenes.count > short.scenes.count)
        #expect(long.estimatedDuration > short.estimatedDuration)
    }

    @Test func atLeastThreeScenesEvenWhenOneIsLong() throws {
        let library = try copiesLibrary(copies: 6, beats: 120)
        let playlist = ListenPlaylist.make(library: library, field: .engineering, choices: .init(length: .five),
                                           learnerName: "", recentlyPlayed: [], seed: 1)
        #expect(try #require(playlist.scenes.first).estimatedDuration > ListenLength.five.targetDuration)
        #expect(playlist.scenes.count == ListenPlaylist.minimumScenes)
    }

    @Test func atMostTenScenesEvenWhenTheyAreShort() throws {
        let library = try copiesLibrary(copies: 25, beats: 1)
        let playlist = ListenPlaylist.make(library: library, field: .engineering, choices: .init(length: .ten),
                                           learnerName: "", recentlyPlayed: [], seed: 1)
        #expect(playlist.scenes.count == ListenPlaylist.maximumScenes)
        #expect(playlist.estimatedDuration < ListenLength.ten.targetDuration)
    }

    @Test func estimatesJapaneseByCharactersAndEnglishByWords() {
        let japanese = SpeechRequest(text: "いいえ、特に問題はありません。", language: .japanese, rate: 1, pauseAfter: 0.8)
        #expect(abs(ListenPlaylist.estimatedDuration(of: japanese) - (15.0 / 6 + 0.8)) < 0.001)
        var slower = japanese
        slower.rate = 0.8
        #expect(ListenPlaylist.estimatedDuration(of: slower) > ListenPlaylist.estimatedDuration(of: japanese))
        let english = SpeechRequest(text: "No, there's no particular problem.", language: .english, pauseAfter: 0.8)
        #expect(abs(ListenPlaylist.estimatedDuration(of: english) - (5.0 / 2.5 + 0.8)) < 0.001)
    }

    // MARK: - Order

    @Test func scenesHeardLatelyComeLast() throws {
        let library = try bundled()
        let everything = ListenPlaylist.scenarios(in: library, field: .engineering, source: .everything).map(\.id)
        let fresh = Array(everything.prefix(4))
        let recent = Array(everything.dropFirst(4))
        let playlist = ListenPlaylist.make(library: library, field: .engineering, choices: .init(length: .ten),
                                           learnerName: "", recentlyPlayed: recent, seed: 3)
        #expect(playlist.scenes.count > fresh.count)
        #expect(Set(playlist.scenes.prefix(fresh.count).map(\.id)) == Set(fresh))
        // Then the ones heard longest ago.
        let rest = playlist.scenes.dropFirst(fresh.count).map(\.id)
        #expect(rest == Array(recent.filter { rest.contains($0) }))
        #expect(rest.first == recent.first)
    }

    @Test func theShuffleChangesWithTheSeed() throws {
        let library = try bundled()
        let orders = Set((1...6).map { seed in
            ListenPlaylist.make(library: library, field: .engineering, choices: .init(), learnerName: "",
                                recentlyPlayed: [], seed: UInt64(seed)).scenes.map(\.id)
        })
        #expect(orders.count > 1)
    }

    @Test func remembersTheLastThirtyLatestLast() {
        var recent: [String] = []
        for index in 0..<40 { recent = ListenPlaylist.remembering("s\(index)", in: recent) }
        #expect(recent.count == ListenPlaylist.recentMemory)
        #expect(recent.first == "s10")
        #expect(recent.last == "s39")
        recent = ListenPlaylist.remembering("s20", in: recent)
        #expect(recent.count == ListenPlaylist.recentMemory)
        #expect(recent.last == "s20")
        #expect(recent.filter { $0 == "s20" }.count == 1)
    }

    // MARK: - Sources

    @Test func sourcesOfferTheirOwnScenes() throws {
        let library = try bundled().including([Self.speech], learnerName: "")
        let work = ListenPlaylist.scenarios(in: library, field: .engineering, source: .myWork)
        #expect(!work.isEmpty)
        #expect(work.allSatisfy { $0.track == .work && $0.workField == .engineering })
        let everyday = ListenPlaylist.scenarios(in: library, field: .engineering, source: .everyday)
        #expect(!everyday.isEmpty)
        #expect(everyday.allSatisfy { $0.track == .everyday && $0.workField == nil && !$0.isLearnersOwn })
        // Someone in finance also hears "Money in Japan".
        let financeEveryday = ListenPlaylist.scenarios(in: library, field: .finance, source: .everyday)
        #expect(financeEveryday.contains { $0.workField == .finance })
        #expect(financeEveryday.count > everyday.count)
        #expect(ListenPlaylist.scenarios(in: library, field: .engineering, source: .myScenes).map(\.id) == ["my.speech"])
        let everything = ListenPlaylist.scenarios(in: library, field: .engineering, source: .everything)
        #expect(everything.contains { $0.id == "my.speech" })
        #expect(!everything.contains { $0.workField == .finance })
    }

    @Test func anEmptySourceFallsBackToEverything() throws {
        let library = try bundled()
        let playlist = ListenPlaylist.make(library: library, field: .engineering, choices: .init(source: .myScenes),
                                           learnerName: "", recentlyPlayed: [], seed: 1)
        #expect(playlist.source == .everything)
        #expect(playlist.choices.source == .myScenes)
        #expect(playlist.scenes.count >= ListenPlaylist.minimumScenes)
    }

    @Test func aSourceWithFewScenesPlaysThemAll() throws {
        let library = try bundled().including([Self.speech], learnerName: "")
        let playlist = ListenPlaylist.make(library: library, field: .engineering, choices: .init(source: .myScenes),
                                           learnerName: "", recentlyPlayed: [], seed: 1)
        #expect(playlist.source == .myScenes)
        #expect(playlist.scenes.map(\.id) == ["my.speech"])
    }

    // MARK: - What is said

    @Test func japaneseOnlyHasNoEnglish() throws {
        let library = try bundled()
        let playlist = ListenPlaylist.make(library: library, field: .engineering, choices: .init(language: .japaneseOnly),
                                           learnerName: "Swapnil", recentlyPlayed: [], seed: 5)
        #expect(requests(playlist).allSatisfy { $0.language == .japanese })
        #expect(!playlist.scenes.flatMap(\.utterances).contains { $0.kind == .translation })
        let first = try #require(playlist.scenes.first)
        #expect(first.utterances.first?.request.text == "場面1。\(first.titleJa)。")
        #expect(playlist.scenes.last?.utterances.first?.request.text.hasPrefix("場面\(playlist.scenes.count)。") == true)
        #expect(playlist.ending.map(\.request.text) == [ListenPlaylist.endingJa])
    }

    @Test func withEnglishEachLineIsFollowedByItsMeaning() throws {
        let library = try bundled()
        let playlist = ListenPlaylist.make(library: library, field: .engineering, choices: .init(language: .withEnglish),
                                           learnerName: "Swapnil", recentlyPlayed: [], seed: 5)
        let first = try #require(playlist.scenes.first)
        #expect(first.utterances.first?.request.text.hasPrefix("Scene 1: ") == true)
        #expect(first.utterances.first?.request.language == .english)
        #expect(first.utterances.contains { $0.kind == .announcement && $0.request.text == first.titleJa })
        for scene in playlist.scenes {
            let said = scene.utterances
            for (index, utterance) in said.enumerated() where utterance.kind == .line && !utterance.english.isEmpty {
                #expect(utterance.request.language == .japanese)
                #expect(utterance.request.pauseAfter == ListenPlaylist.pauseBeforeTranslation)
                let next = try #require(index + 1 < said.count ? said[index + 1] : nil)
                #expect(next.kind == .translation)
                #expect(next.request.text == utterance.english)
                #expect(next.request.language == .english)
                #expect(next.request.voice == .coachEnglish)
                #expect(next.japanese == utterance.japanese)
            }
        }
        #expect(playlist.ending.map(\.request.text) == [ListenPlaylist.endingJa, ListenPlaylist.endingEn])
    }

    @Test func linesAreInScriptOrderInTheirSpeakersVoices() throws {
        let library = try bundled().including([Self.chat], learnerName: "Swapnil")
        let scenario = try #require(library.scenario(id: "my.chat"))
        let scene = ListenPlaylist.scene(scenario, number: 2, library: library, choices: .init(), learnerName: "Swapnil")
        let lines = scene.utterances.filter { $0.kind == .line }
        #expect(lines.map(\.request.text) == ["Swapnilさん、お昼どうですか。", "はい、行きましょう。", "何にしますか。",
                                              "じゃあ、行きましょう。"])
        #expect(lines.map(\.speaker) == ["Sato", "You", "You", "Sato"])
        #expect(lines[0].request.voice == .partner(.male))
        #expect(lines[1].request.voice == .coachJapanese)
        #expect(lines[3].request.voice == .partner(.male))
        #expect(scene.utterances.first?.request.text == "場面2。昼ご飯。")
    }

    @Test func pausesAfterLinesAndBetweenScenes() throws {
        let library = try bundled()
        let playlist = ListenPlaylist.make(library: library, field: .engineering, choices: .init(),
                                           learnerName: "", recentlyPlayed: [], seed: 9)
        for scene in playlist.scenes {
            #expect(scene.utterances.last?.request.pauseAfter == ListenPlaylist.pauseBetweenScenes)
            #expect(scene.utterances.dropLast().allSatisfy { $0.request.pauseAfter == ListenPlaylist.pauseAfterLine })
        }
    }

    @Test func slowerSlowsOnlyTheJapanese() throws {
        let library = try bundled()
        let playlist = ListenPlaylist.make(library: library, field: .engineering,
                                           choices: .init(language: .withEnglish, speed: .slower),
                                           learnerName: "", recentlyPlayed: [], seed: 4)
        let said = requests(playlist)
        #expect(said.filter { $0.language == .japanese }.allSatisfy { $0.rate == 0.8 })
        #expect(said.filter { $0.language == .english }.allSatisfy { $0.rate == 1.0 })
        let natural = ListenPlaylist.make(library: library, field: .engineering, choices: .init(), learnerName: "",
                                          recentlyPlayed: [], seed: 4)
        #expect(requests(natural).allSatisfy { $0.rate == 1.0 })
    }

    @Test func theLearnersNameIsFilledIn() throws {
        let library = try bundled().including([Self.speech, Self.chat], learnerName: "Swapnil")
        let playlist = ListenPlaylist.make(library: library, field: .engineering,
                                           choices: .init(language: .withEnglish, source: .myScenes),
                                           learnerName: "Swapnil", recentlyPlayed: [], seed: 1)
        let said = texts(playlist)
        #expect(said.contains("Swapnilです。"))
        #expect(said.contains("I'm Swapnil."))
        #expect(!said.contains { $0.contains("{name}") })
        #expect(!playlist.scenes.flatMap(\.utterances).contains { $0.japanese.contains("{name}") || $0.kana.contains("{name}") })
    }

    @Test func withoutANameThePlaceholderIsLeftOut() throws {
        let library = try bundled().including([Self.speech, Self.chat], learnerName: "")
        let playlist = ListenPlaylist.make(library: library, field: .engineering,
                                           choices: .init(language: .withEnglish, source: .myScenes),
                                           learnerName: "", recentlyPlayed: [], seed: 1)
        let said = texts(playlist)
        #expect(!said.contains { $0.contains("{name}") })
        #expect(said.contains("お昼どうですか。"))
        #expect(ListenPlaylist.filled("{name}さん、お昼どうですか。", name: "") == "お昼どうですか。")
        #expect(ListenPlaylist.filled("{name}, how about lunch?", name: " ") == "how about lunch?")
        #expect(ListenPlaylist.filled("{name}です。", name: "Swapnil") == "Swapnilです。")
    }

    @Test func aSpeechHasNoPartnerAndNoEmptyLines() throws {
        let library = try bundled().including([Self.speech], learnerName: "Swapnil")
        let scenario = try #require(library.scenario(id: "my.speech"))
        for language in ListenLanguage.allCases {
            let scene = ListenPlaylist.scene(scenario, number: 1, library: library, choices: .init(language: language),
                                             learnerName: "Swapnil")
            #expect(!scene.utterances.contains { utterance in
                if case .partner = utterance.request.voice { return true }
                return false
            })
            #expect(!scene.utterances.contains { $0.request.text.trimmingCharacters(in: .whitespaces).isEmpty })
            #expect(scene.utterances.filter { $0.kind == .line }.map(\.request.text)
                    == ["おはようございます。", "Swapnilです。", "インドから来ました。"])
            #expect(scene.utterances.filter { $0.kind == .line }.allSatisfy { $0.speaker == "You" })
        }
    }

    @Test func emptyPartnerLinesAreSkipped() throws {
        let library = try bundled()
        for scenario in library.scenarios {
            let scene = ListenPlaylist.scene(scenario, number: 1, library: library, choices: .init(language: .withEnglish),
                                             learnerName: "")
            #expect(!scene.utterances.contains { $0.request.text.trimmingCharacters(in: .whitespaces).isEmpty },
                    "\(scenario.id)")
            let partnerLines = scenario.beats.filter { !$0.line.isEmpty }.count + (scenario.closingLine.isEmpty ? 0 : 1)
            let spokenByPartner = scene.utterances.filter { utterance in
                guard utterance.kind == .line, case .partner = utterance.request.voice else { return false }
                return true
            }
            #expect(spokenByPartner.count == partnerLines, "\(scenario.id)")
        }
    }

    @Test func nothingToPlayMakesAnEmptyPlaylist() {
        let playlist = ListenPlaylist.make(library: ContentLibrary(items: []), field: .engineering, choices: .init(),
                                           learnerName: "", recentlyPlayed: [], seed: 1)
        #expect(playlist.isEmpty)
        #expect(playlist.ending.isEmpty)
    }
}
