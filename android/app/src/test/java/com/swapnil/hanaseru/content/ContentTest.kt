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
    fun scenesListTheWordsTheirLinesUse() {
        val words = library.vocabulary(library.scenario("s.weekend.chat")!!).map { it.japanese }
        for (word in listOf("週末", "友達", "映画", "行く", "決める")) assertTrue(word, word in words)
    }
}
