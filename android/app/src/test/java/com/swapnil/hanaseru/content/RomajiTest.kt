package com.swapnil.hanaseru.content

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The same expectations as the iPhone app's RomajiTests. */
class RomajiTest {
    @Test
    fun kana() {
        val cases = mapOf(
            "しんかんせん" to "shinkansen",
            "きょう" to "kyō",
            "がっこう" to "gakkō",
            "まっちゃ" to "matcha",
            "こんや" to "kon'ya",
            "げんいん" to "gen'in",
            "コーヒー" to "kōhī",
            "ちゅうい" to "chūi",
            "おおきい" to "ōkii",
            "しゃしん" to "shashin",
            "じゅんちょう" to "junchō",
            "ありがとう" to "arigatō",
            "ファイル" to "fairu",
        )
        for ((kana, expected) in cases) assertEquals(kana, expected, Romaji.fromKana(kana))
    }

    @Test
    fun particlesAreWrittenAsTheyAreSaid() {
        assertEquals("wa", Romaji.romanize("は"))
        assertEquals("o", Romaji.romanize("を"))
        assertEquals("e", Romaji.romanize("へ"))
        assertEquals("dewa", Romaji.romanize("では"))
        assertEquals("hai", Romaji.romanize("はい"))
    }

    @Test
    fun endingsStayWithTheirWord() {
        val words = Romaji.glue(listOf("あり", "ませ", "ん", "。").map { Romaji.Piece(it, it) })
        assertEquals(listOf("ありません", "。"), words)
        assertEquals("Mondai wa arimasen.", Romaji.sentence(listOf("もんだい", "は", "ありません", "。")))
        assertEquals("Hai, sō desu.", Romaji.sentence(listOf("はい", "、", "そう", "です", "。")))
    }

    @Test
    fun wordsLineUpWithTheKana() {
        val words = Romaji.alignedWords(listOf("いいえ", "、", "特に", "問題", "は", "ありません", "。"),
                                        "いいえ、とくにもんだいはありません。")!!
        val romaji = Romaji.sentence(Romaji.glue(words))
        assertEquals("Iie, tokuni mondai wa arimasen.", romaji)
    }

    @Test
    fun kanjiWithoutAReadingGivesNothing() {
        assertTrue(Romaji.of("問題", "").isEmpty())
    }
}
