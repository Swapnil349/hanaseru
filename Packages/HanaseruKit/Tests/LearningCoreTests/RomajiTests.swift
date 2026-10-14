import Testing
@testable import LearningCore

@Suite("Romaji: Japanese in English letters")
struct RomajiTests {
    @Test(arguments: [
        ("しんかんせん", "shinkansen"),
        ("きょう", "kyō"),
        ("がっこう", "gakkō"),
        ("まっちゃ", "matcha"),
        ("こんや", "kon'ya"),
        ("げんいん", "gen'in"),
        ("コーヒー", "kōhī"),
        ("ちゅうい", "chūi"),
        ("おおきい", "ōkii"),
        ("しゃしん", "shashin"),
        ("じゅんちょう", "junchō"),
        ("ありがとう", "arigatō"),
        ("ファイル", "fairu"),
    ])
    func kana(_ kana: String, _ expected: String) {
        #expect(Romaji.fromKana(kana) == expected)
    }

    @Test func particlesAreWrittenAsTheyAreSaid() {
        #expect(Romaji.romanize("は") == "wa")
        #expect(Romaji.romanize("を") == "o")
        #expect(Romaji.romanize("へ") == "e")
        #expect(Romaji.romanize("では") == "dewa")
        #expect(Romaji.romanize("はい") == "hai")
    }

    @Test func endingsStayWithTheirWord() {
        let words = Romaji.glue(["あり", "ませ", "ん", "。"].map { Romaji.Piece(kana: $0, surface: $0) })
        #expect(words == ["ありません", "。"])
        #expect(Romaji.sentence(["もんだい", "は", "ありません", "。"]) == "Mondai wa arimasen.")
        #expect(Romaji.sentence(["はい", "、", "そう", "です", "。"]) == "Hai, sō desu.")
    }

    @Test func aSentenceWithKanjiUsesItsKana() {
        let romaji = Romaji.of("いいえ、特に問題はありません。", kana: "いいえ、とくにもんだいはありません。")
        #expect(romaji.hasPrefix("Iie, "), "\(romaji)")
        #expect(romaji.contains("mondai wa "), "\(romaji)")
        #expect(romaji.hasSuffix(" arimasen."), "\(romaji)")
    }

    @Test func kanjiWithoutAReadingGivesNothing() {
        #expect(Romaji.of("問題", kana: "").isEmpty)
    }

    @Test func everyLineInTheCourseHasRomaji() throws {
        let library = try ContentLibrary.bundled()
        for scenario in library.scenarios {
            for line in library.lines(in: scenario, learnerName: "Swapnil") {
                #expect(!line.romaji.isEmpty, "\(line.id)")
                #expect(!line.romaji.contains(where: { "ぁ"..."ヿ" ~= $0 }), "\(line.id): \(line.romaji)")
                if let partner = line.partner {
                    #expect(!partner.romaji.isEmpty, "\(line.id) partner")
                }
            }
        }
    }

    @Test func scenesListTheWordsTheirLinesUse() throws {
        let library = try ContentLibrary.bundled()
        let weekend = try #require(library.scenario(id: "s.weekend.chat"))
        let words = library.vocabulary(in: weekend).map(\.japanese)
        for word in ["週末", "友達", "映画", "行く", "決める"] {
            #expect(words.contains(word), "\(word)")
        }
        let pier = try #require(library.scenario(id: "s.site.pier"))
        #expect(library.vocabulary(in: pier).contains { $0.japanese == "送る" })
    }
}
