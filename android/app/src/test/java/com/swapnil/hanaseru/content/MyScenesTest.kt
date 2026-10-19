package com.swapnil.hanaseru.content

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class MyScenesTest {
    private val library = ContentLibrary.load { name ->
        File("../../Packages/HanaseruKit/Sources/LearningCore/Content/$name").readText()
    }

    private fun line(japanese: String, kana: String, english: String, vararg words: SceneWord) =
        SceneLine(japanese, kana, english, words.toList())

    private val conversation = SavedScene(
        id = "my.test1",
        kind = SavedScene.KIND_CONVERSATION,
        description = "Asking which platform the train leaves from",
        createdAt = 1_760_866_200_000L,
        updatedAt = 1_760_866_200_000L,
        result = SceneResult(
            title = "Which platform?", titleJa = "何番線ですか", situationEn = "At the station.", placeEn = "at the station",
            partnerNameJa = "駅員さん", partnerNameEn = "Station attendant", partnerRole = "Station staff", partnerGender = "female",
            track = "everyday",
            beats = listOf(
                SceneResultBeat(
                    partner = line("いらっしゃいませ。", "いらっしゃいませ。", "Hello, can I help?",
                                   SceneWord("いらっしゃいませ", "いらっしゃいませ", "welcome")),
                    learner = line("{name}です。新幹線は何番線ですか。", "{name}です。しんかんせんはなんばんせんですか。",
                                   "I'm {name}. Which platform is the Shinkansen?",
                                   SceneWord("{name}", "{name}", "your name"), SceneWord("新幹線", "しんかんせん", "bullet train"),
                                   SceneWord("何番線", "なんばんせん", "which platform")),
                    hintEn = "Ask which platform",
                ),
                SceneResultBeat(
                    partner = line("十四番線です。", "じゅうよんばんせんです。", "Platform 14."),
                    learner = line("ありがとうございます。", "ありがとうございます。", "Thank you."),
                    hintEn = "Thank them",
                ),
            ),
            closing = line("お気をつけて。", "おきをつけて。", "Have a safe trip."),
        ),
    )

    private val speech = SavedScene(
        id = "my.speech1",
        kind = SavedScene.KIND_MONOLOGUE,
        description = "Introducing myself to the team",
        result = SceneResult(
            title = "Meeting the new team", titleJa = "新しいチームへの挨拶", situationEn = "Your first day.",
            track = "work",
            beats = listOf(
                SceneResultBeat(learner = line("はじめまして。", "はじめまして。", "Nice to meet you."), hintEn = "Greet them"),
                SceneResultBeat(learner = line("{name}と申します。", "{name}ともうします。", "My name is {name}.",
                                               SceneWord("{name}", "{name}", "your name"),
                                               SceneWord("申します", "もうします", "am called (humble)")),
                                hintEn = "Say your name"),
                SceneResultBeat(learner = line("よろしくお願いいたします。", "よろしくおねがいいたします。", "I look forward to working with you."),
                                hintEn = "Close politely"),
            ),
        ),
    )

    @Test
    fun aSavedSceneBecomesAnOrdinaryScene() {
        val scenario = conversation.toScenario()
        assertEquals("my.test1", scenario.id)
        assertEquals("Which platform?", scenario.title)
        assertEquals("my.test1.partner", scenario.personaID)
        assertEquals(listOf("b1", "b2"), scenario.beats.map { it.id })
        assertEquals("いらっしゃいませ。", scenario.beats[0].line)
        assertEquals("Ask which platform", scenario.beats[0].hintEn)
        assertEquals("Ask which platform", scenario.beats[0].intentEn)
        assertEquals(1, scenario.beats[0].responses.size)
        assertEquals("お気をつけて。", scenario.closingLine)
        assertTrue(scenario.targetTerms.isEmpty())
        assertNull(scenario.field)
        val persona = conversation.toPersona()
        assertEquals("Station attendant", persona.nameEn)
        assertTrue(persona.isFemale)
        assertEquals(1.0, persona.speakingRate, 0.0)
    }

    @Test
    fun theLibraryIncludesMyScenes() {
        val all = library.including(listOf(conversation, speech))
        assertEquals(library.scenarios.size + 2, all.scenarios.size)
        val scenario = all.scenario("my.test1")!!
        assertEquals("駅員さん", all.persona(scenario.personaID)?.nameJa)
        val lines = all.lines(scenario, "スワプニル")
        assertEquals(2, lines.size)
        assertEquals("スワプニルです。新幹線は何番線ですか。", lines[0].japanese)
        assertEquals("いらっしゃいませ。", lines[0].partner?.japanese)
        // The Words button finds every line's words, the learner's name included.
        assertTrue(all.words(lines[0].japanese).any { it.ja == "新幹線" })
        assertTrue(all.words(lines[0].japanese).any { it.ja == "スワプニル" })
        assertTrue(all.words("いらっしゃいませ。").isNotEmpty())
        // The course is unchanged.
        assertEquals(library.words("おはようございます。今日はよろしくお願いします。"),
                     all.words("おはようございます。今日はよろしくお願いします。"))
        // Playing the other side works as for any scene.
        assertEquals(listOf("いらっしゃいませ。", "十四番線です。", "お気をつけて。"),
                     all.partnerSideLines(scenario, "").map { it.japanese })
    }

    @Test
    fun aSpeechHasNoOtherSide() {
        val all = library.including(listOf(speech))
        val scenario = all.scenario("my.speech1")!!
        assertTrue(scenario.beats.all { it.line.isEmpty() })
        assertEquals("", scenario.closingLine)
        val lines = all.lines(scenario, "")
        assertEquals(3, lines.size)
        assertTrue(lines.all { it.partner == null && it.japanese.isNotEmpty() && it.romaji.isNotEmpty() })
        // Its script is just your lines; there is no other role to play.
        val script = all.script(scenario, "")
        assertEquals(3, script.size)
        assertTrue(script.all { it.isLearner && it.japanese.isNotEmpty() })
        assertTrue(all.partnerSideLines(scenario, "").isEmpty())
        assertTrue(all.words(lines[1].japanese).any { it.ja == "申します" })
    }

    @Test
    fun beatsWithNothingToSayAreLeftOut() {
        val broken = conversation.copy(result = conversation.result.copy(
            beats = conversation.result.beats + SceneResultBeat(partner = line("はい。", "はい。", "Yes."))))
        assertEquals(2, broken.lineCount)
        assertEquals(2, broken.toScenario().beats.size)
    }

    @Test
    fun filesHoldOneSceneOrMany() {
        val one = MyScenes.decode(MyScenes.encode(conversation))
        assertEquals(listOf(conversation), one)
        val many = MyScenes.decode(MyScenes.encode(listOf(conversation, speech)))
        assertEquals(listOf(conversation, speech), many)
        // A speech's empty other side is written out, as the shared format has it.
        val text = MyScenes.encode(speech)
        assertTrue(text.contains("\"partner\""))
        assertTrue(text.contains("\"closing\""))
        assertTrue(text.contains("\"createdAt\": 0") || text.contains("\"createdAt\":0"))
        // Another app's file: unknown fields ignored, a time written as an ISO date still reads.
        val other = MyScenes.decode("""
            {"id":"my.x","description":"d","createdAt":1760000000000,"updatedAt":"2026-10-19T09:30:00Z",
             "extra":true,"result":{"title":"T","beats":[{"partner":{"japanese":"","kana":"","english":"","words":[]},
             "learner":{"japanese":"はじめまして。","kana":"はじめまして。","english":"Hello.","words":[]},"hintEn":"Greet"}],
             "closing":{"japanese":"","kana":"","english":"","words":[]}}}
        """.trimIndent())
        assertEquals(1, other.size)
        // No kind given, but nobody else speaks: a speech.
        assertTrue(other[0].isMonologue)
        assertEquals(1_760_000_000_000L, other[0].createdAt)
        assertEquals(1_792_402_200_000L, other[0].updatedAt)
        assertEquals(1, other[0].lineCount)
    }

    @Test
    fun importingReplacesAndKeepsApart() {
        val changed = conversation.copy(result = conversation.result.copy(title = "Which platform, please?"))
        val (merged, count) = MyScenes.merge(listOf(conversation, speech), listOf(changed, speech.copy(id = "abc")), 5L)
        assertEquals(2, count)
        assertEquals(listOf("my.test1", "my.abc", "my.speech1"), merged.map { it.id })
        assertEquals("Which platform, please?", merged[0].result.title)
        // A scene with nothing to practise isn't imported; one with no id gets one.
        val (_, none) = MyScenes.merge(emptyList(), listOf(SavedScene(id = "my.empty")), 5L)
        assertEquals(0, none)
        val (named, _) = MyScenes.merge(emptyList(), listOf(speech.copy(id = "", createdAt = 0L)), 5L)
        assertTrue(named[0].id.startsWith("my."))
        assertEquals(5L, named[0].createdAt)
        assertFalse(named[0].id == "my.")
    }
}
