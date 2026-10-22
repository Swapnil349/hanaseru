package com.swapnil.hanaseru.listen

import com.swapnil.hanaseru.content.ContentLibrary
import com.swapnil.hanaseru.content.ModelLine
import com.swapnil.hanaseru.content.Persona
import com.swapnil.hanaseru.content.SavedScene
import com.swapnil.hanaseru.content.Scenario
import com.swapnil.hanaseru.content.ScenarioBeat
import com.swapnil.hanaseru.content.SceneLine
import com.swapnil.hanaseru.content.SceneResult
import com.swapnil.hanaseru.content.SceneResultBeat
import com.swapnil.hanaseru.content.including
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.random.Random

class ListenPlaylistTest {
    private val library = ContentLibrary.load { name ->
        File("../../Packages/HanaseruKit/Sources/LearningCore/Content/$name").readText()
    }

    private fun build(
        options: ListenOptions,
        lib: ContentLibrary = library,
        field: String = "engineering",
        mine: Set<String> = emptySet(),
        name: String = "Swapnil",
        recent: List<String> = emptyList(),
        seed: Int = 7,
    ) = ListenPlaylist.build(lib, options, field, mine, name, recent, Random(seed))

    private fun tiny(id: String, track: String = "everyday", field: String? = null) = Scenario(
        id = id, title = "Tiny $id", titleJa = "小さい", track = track, personaID = "p", field = field,
        beats = listOf(ScenarioBeat(line = "はい。", responses = listOf(ModelLine("はい。", "はい。", "Yes.")))),
    )

    private fun libraryOf(scenes: List<Scenario>) = ContentLibrary(
        items = emptyList(), scenarios = scenes, personas = listOf(Persona("p", nameEn = "Tanaka", voiceGender = "female")),
        vocabulary = emptyList(), cues = emptyMap(),
    )

    @Test
    fun aPlaylistReachesItsLength() {
        for (language in ListenLanguage.entries) {
            for (length in ListenLength.entries) {
                for (seed in 1..5) {
                    val playlist = build(ListenOptions(language, length, ListenSource.EVERYTHING), seed = seed)
                    val sceneSeconds = playlist.scenes.sumOf { ListenPlaylist.estimatedSeconds(it.utterances) }
                    assertTrue("$language $length: ${playlist.scenes.size} scenes",
                               playlist.scenes.size == ListenPlaylist.MAX_SCENES || sceneSeconds >= length.seconds)
                    // Not much longer than asked: the last scene added is what tipped it over.
                    val withoutLast = sceneSeconds - ListenPlaylist.estimatedSeconds(playlist.scenes.last().utterances)
                    assertTrue(playlist.scenes.size <= ListenPlaylist.MIN_SCENES || withoutLast < length.seconds)
                }
            }
        }
    }

    @Test
    fun aPlaylistHoldsThreeToTenScenes() {
        // Very short scenes: stops at ten, however short the playlist still is.
        val short = build(ListenOptions(length = ListenLength.TEN, source = ListenSource.EVERYTHING),
                          lib = libraryOf((1..20).map { tiny("t$it") }))
        assertEquals(ListenPlaylist.MAX_SCENES, short.scenes.size)
        assertTrue(short.estimatedSeconds < ListenLength.TEN.seconds)

        // Very long scenes: still at least three.
        val long = Scenario(
            id = "long", title = "Long", titleJa = "長い", track = "everyday", personaID = "p",
            beats = (1..60).map { ScenarioBeat(line = "とても長い文です。".repeat(4), responses = listOf(ModelLine("わかりました。"))) },
        )
        val longs = libraryOf((1..5).map { long.copy(id = "long$it") })
        assertTrue(ListenPlaylist.estimatedSeconds(ListenPlaylist.scene(longs, longs.scenarios[0], 1, ListenOptions(), "")
            .utterances) > ListenLength.FIVE.seconds)
        assertEquals(ListenPlaylist.MIN_SCENES, build(ListenOptions(source = ListenSource.EVERYTHING), lib = longs).scenes.size)

        for (source in ListenSource.entries) {
            val playlist = build(ListenOptions(source = source))
            assertTrue("$source", playlist.scenes.size in ListenPlaylist.MIN_SCENES..ListenPlaylist.MAX_SCENES)
        }
    }

    @Test
    fun scenesHeardLatelyComeLast() {
        val all = libraryOf((1..12).map { tiny("t$it") })
        val recent = (1..9).map { "t$it" }
        for (seed in 1..10) {
            val order = ListenPlaylist.order(all.scenarios, recent, Random(seed)).map { it.id }
            assertEquals(setOf("t10", "t11", "t12"), order.take(3).toSet())
            // The ones heard longest ago come back first.
            assertEquals(recent, order.drop(3))
        }
        val playlist = build(ListenOptions(source = ListenSource.EVERYTHING), lib = all, recent = recent)
        assertEquals(setOf("t10", "t11", "t12"), playlist.scenes.take(3).map { it.id }.toSet())
    }

    @Test
    fun recentlyPlayedKeepsTheLastThirty() {
        var recent = emptyList<String>()
        for (index in 1..40) recent = ListenPlaylist.remember(recent, "s$index")
        assertEquals(30, recent.size)
        assertEquals("s11", recent.first())
        recent = ListenPlaylist.remember(recent, "s11")
        assertEquals("s11", recent.last())
        assertEquals(30, recent.size)
    }

    @Test
    fun englishOnlyWithJapaneseAndEnglish() {
        val japanese = build(ListenOptions(ListenLanguage.JAPANESE, source = ListenSource.EVERYTHING))
        for (scene in japanese.scenes) {
            assertTrue(scene.utterances.none { it.voice == ListenVoice.ENGLISH })
            assertTrue(scene.utterances.first().text.startsWith("場面"))
        }
        assertEquals(listOf("おしまいです。お疲れさまでした。"), japanese.ending.map { it.text })

        val both = build(ListenOptions(ListenLanguage.JAPANESE_ENGLISH, source = ListenSource.EVERYTHING))
        for ((index, scene) in both.scenes.withIndex()) {
            assertTrue(scene.utterances.first().text.startsWith("Scene ${index + 1}: "))
            assertEquals(ListenVoice.ENGLISH, scene.utterances.first().voice)
            // Every line of the script is followed by its English, after a short pause.
            val script = scene.utterances.dropWhile { it.speaker == "Hanaseru" }
            script.forEachIndexed { at, utterance ->
                if (utterance.voice != ListenVoice.ENGLISH && utterance.english.isNotBlank()) {
                    assertEquals(ListenPlaylist.BEFORE_ENGLISH_MILLIS, utterance.pauseAfterMillis)
                    assertEquals(ListenVoice.ENGLISH, script[at + 1].voice)
                    assertEquals(utterance.english, script[at + 1].text)
                }
            }
        }
        assertEquals("That's the end. Well done.", both.ending.last().text)
    }

    @Test
    fun theScriptIsInOrderWithPauses() {
        val scenario = library.scenarios.first { it.beats.all { beat -> beat.line.isNotEmpty() } && it.closingLine.isNotEmpty() }
        val scene = ListenPlaylist.scene(library, scenario, 2, ListenOptions(speed = ListenSpeed.SLOWER), "Swapnil")
        val expected = listOf("場面2。${scenario.titleJa}。") +
            scenario.beats.flatMap { listOf(it.line, it.responses.first().japanese.replace("{name}", "Swapnil")) } +
            scenario.closingLine
        assertEquals(expected, scene.utterances.map { it.text })
        assertTrue(scene.utterances.all { it.rate == 0.8f })
        assertTrue(scene.utterances.dropLast(1).all { it.pauseAfterMillis == ListenPlaylist.LINE_PAUSE_MILLIS })
        assertEquals(ListenPlaylist.SCENE_PAUSE_MILLIS, scene.utterances.last().pauseAfterMillis)
        // The other person and you are different voices.
        assertTrue(scene.utterances[1].voice != ListenVoice.COACH_JAPANESE)
        assertEquals(ListenVoice.COACH_JAPANESE, scene.utterances[2].voice)
        assertEquals("You", scene.utterances[2].speaker)
    }

    @Test
    fun theLearnersNameIsFilledIn() {
        val named = library.scenarios.first { scene -> scene.beats.any { beat -> beat.responses.any { "{name}" in it.japanese } } }
        val withName = ListenPlaylist.scene(library, named, 1, ListenOptions(ListenLanguage.JAPANESE_ENGLISH), "Swapnil")
        assertTrue(withName.utterances.none { "{name}" in it.text || "{name}" in it.japanese || "{name}" in it.kana })
        assertTrue(withName.utterances.any { "Swapnil" in it.text })
        val nameless = ListenPlaylist.scene(library, named, 1, ListenOptions(ListenLanguage.JAPANESE_ENGLISH), "")
        assertTrue(nameless.utterances.none { "{name}" in it.text || "…" in it.text })
        assertEquals("I'm.", ListenPlaylist.fillEnglish("I'm {name}.", ""))
    }

    @Test
    fun emptyPartnerLinesAreSkipped() {
        val scenario = Scenario(
            id = "s", title = "S", titleJa = "エス", personaID = "p",
            beats = listOf(
                ScenarioBeat(line = "", responses = listOf(ModelLine("おはようございます。", "", "Good morning."))),
                ScenarioBeat(line = "はい、おはよう。", english = "Morning.", responses = listOf(ModelLine("今日も暑いですね。"))),
            ),
        )
        val lib = libraryOf(listOf(scenario))
        val scene = ListenPlaylist.scene(lib, scenario, 1, ListenOptions(), "")
        assertEquals(listOf("場面1。エス。", "おはようございます。", "はい、おはよう。", "今日も暑いですね。"),
                     scene.utterances.map { it.text })
        assertTrue(scene.utterances.none { it.text.isBlank() })
        assertEquals(ListenVoice.PARTNER_FEMALE, scene.utterances[2].voice)
    }

    @Test
    fun aSpeechIsAllYourLines() {
        val speech = SavedScene(
            id = "my.speech", kind = SavedScene.KIND_MONOLOGUE,
            result = SceneResult(
                title = "Speech", titleJa = "挨拶", situationEn = "Your first day.",
                beats = listOf(
                    SceneResultBeat(learner = SceneLine("はじめまして。", "はじめまして。", "Nice to meet you.")),
                    SceneResultBeat(learner = SceneLine("{name}と申します。", "{name}ともうします。", "I'm {name}.")),
                ),
            ),
        )
        val lib = library.including(listOf(speech))
        val options = ListenOptions(ListenLanguage.JAPANESE_ENGLISH, source = ListenSource.MY_SCENES)
        val playlist = ListenPlaylist.build(lib, options, "engineering", setOf("my.speech"), "Swapnil", emptyList(), Random(1))
        assertEquals(listOf("my.speech"), playlist.scenes.map { it.id })
        val spoken = playlist.scenes[0].utterances.filter { it.voice != ListenVoice.ENGLISH }.map { it.text }
        assertEquals(listOf("挨拶", "はじめまして。", "Swapnilと申します。"), spoken)
        assertTrue(playlist.scenes[0].utterances.filter { it.speaker == "You" && it.voice != ListenVoice.ENGLISH }
                       .all { it.voice == ListenVoice.COACH_JAPANESE })
    }

    @Test
    fun anEmptySourceFallsBackToEverything() {
        val playlist = build(ListenOptions(source = ListenSource.MY_SCENES))
        assertTrue(playlist.scenes.size >= ListenPlaylist.MIN_SCENES)

        val lib = libraryOf(listOf(tiny("w1", "work", "finance"), tiny("e1"), tiny("e2")))
        assertEquals(setOf("e1", "e2", "w1"), build(ListenOptions(source = ListenSource.MY_WORK), lib = lib).scenes.map { it.id }.toSet())
        assertEquals(listOf("w1"), build(ListenOptions(source = ListenSource.MY_WORK), lib = lib, field = "finance").scenes.map { it.id })
    }

    @Test
    fun sourcesPickTheirScenes() {
        val work = build(ListenOptions(source = ListenSource.MY_WORK, length = ListenLength.TEN), field = "finance")
        assertTrue(work.scenes.all { library.scenario(it.id)!!.let { s -> s.track == "work" && s.workField == "finance" } })
        val everyday = build(ListenOptions(source = ListenSource.EVERYDAY, length = ListenLength.TEN), field = "finance")
        assertTrue(everyday.scenes.all { library.scenario(it.id)!!.track == "everyday" })
        val railwayEveryday = build(ListenOptions(source = ListenSource.EVERYDAY, length = ListenLength.TEN))
        assertFalse(railwayEveryday.scenes.any { library.scenario(it.id)!!.workField == "finance" })
    }

    @Test
    fun previousRestartsASceneAfterThreeSeconds() {
        assertEquals(2, ListenPlaylist.previousScene(3, 1_000, 5))
        assertEquals(3, ListenPlaylist.previousScene(3, 10_000, 5))
        assertEquals(0, ListenPlaylist.previousScene(0, 500, 5))
        // From the ending: the last scene.
        assertEquals(4, ListenPlaylist.previousScene(5, 0, 5))
    }
}
