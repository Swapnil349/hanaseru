package com.swapnil.hanaseru.content

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class ContentTest {
    private val library = ContentLibrary.load { name ->
        File("../../Packages/HanaseruKit/Sources/LearningCore/Content/$name").readText()
    }

    @Test
    fun theSharedLessonsLoad() {
        assertTrue(library.scenarios.size >= 10)
        assertTrue(library.items.size >= 40)
        assertTrue(library.vocabulary.size >= 200)
        assertTrue(library.cues.containsKey("watchScene"))
    }

    @Test
    fun everySceneHasItsLinesAndPeople() {
        for (scenario in library.scenarios) {
            assertTrue(scenario.id, library.persona(scenario.personaID) != null)
            val lines = library.lines(scenario, "Swapnil")
            assertEquals(scenario.id, scenario.beats.size, lines.size)
            for (line in lines) {
                assertFalse(line.id, line.japanese.isEmpty())
                assertFalse(line.id, line.romaji.isEmpty())
            }
        }
    }

    @Test
    fun everyLineHasItsWords() {
        for (scenario in library.scenarios) {
            for (line in library.lines(scenario, "Swapnil")) {
                val words = library.words(line.japanese)
                assertFalse("${line.id}: ${line.japanese}", words.isEmpty())
                assertTrue(line.id, words.all { it.en.isNotEmpty() && it.romaji.isNotEmpty() })
            }
        }
        val named = library.words("お電話ありがとうございます。Swapnilです。いつもお世話になっております。")
        assertTrue(named.any { it.ja == "Swapnil" })
        assertTrue(library.scenarios.any { it.workField == "finance" })
    }

    @Test
    fun theScriptHasEveryLineInThreeWays() {
        val scenario = library.scenario("s.weekend.chat")!!
        val entries = library.script(scenario, "")
        val text = scriptText(scenario.title, scenario.situationEn, entries)
        for (line in library.lines(scenario, "")) {
            assertTrue(text.contains(line.japanese))
            assertTrue(text.contains(line.romaji))
            assertTrue(text.contains(line.english))
        }
        assertTrue(text.contains(scenario.closingLine))
    }

    @Test
    fun theLearnerCanPlayTheColleague() {
        val scenario = library.scenario("s.weekend.chat")!!
        val mine = library.lines(scenario, "")
        val theirs = library.partnerSideLines(scenario, "")
        assertEquals(mine.mapNotNull { it.partner?.japanese } + scenario.closingLine, theirs.map { it.japanese })
        assertEquals(null, theirs.first().partner)
        assertEquals(mine.map { it.japanese }, theirs.drop(1).mapNotNull { it.partner?.japanese })
    }

    @Test
    fun answersAreComparedLikeOnTheIPhone() {
        assertEquals(1.0, JapaneseText.similarity("いいえ、特に問題はありません。", "いいえ特に問題はありません"), 0.0001)
        assertEquals(1.0, JapaneseText.similarity("カレー", "かれー"), 0.0001)
        assertTrue(JapaneseText.similarity("友達と出かけました", "友達と出かけた") > 0.6)
        assertEquals(0.0, JapaneseText.similarity("", "はい"), 0.0001)
    }

    @Test
    fun scenesListTheWordsTheirLinesUse() {
        val words = library.vocabulary(library.scenario("s.weekend.chat")!!).map { it.japanese }
        for (word in listOf("週末", "友達", "映画", "行く", "決める")) assertTrue(word, word in words)
    }
}
