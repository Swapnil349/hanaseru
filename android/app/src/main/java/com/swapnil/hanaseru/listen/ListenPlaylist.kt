package com.swapnil.hanaseru.listen

import com.swapnil.hanaseru.content.ContentLibrary
import com.swapnil.hanaseru.content.Scenario
import kotlin.random.Random

// Listen (docs/LISTEN.md): a playlist of short scenes heard back to back, like an audio drama, while driving.
// Everything here is plain Kotlin, so the choice of scenes and what is said can be tested without a phone.

enum class ListenLanguage { JAPANESE, JAPANESE_ENGLISH }

enum class ListenLength(val seconds: Int) { FIVE(300), TEN(600) }

enum class ListenSource { MY_WORK, EVERYDAY, MY_SCENES, EVERYTHING }

enum class ListenSpeed(val rate: Float) { NATURAL(1f), SLOWER(0.8f) }

/** Who says a line. The coach's Japanese voice also says the learner's lines (a different voice from the partner). */
enum class ListenVoice { COACH_JAPANESE, PARTNER_MALE, PARTNER_FEMALE, ENGLISH }

data class ListenOptions(
    val language: ListenLanguage = ListenLanguage.JAPANESE,
    val length: ListenLength = ListenLength.FIVE,
    val source: ListenSource = ListenSource.MY_WORK,
    val speed: ListenSpeed = ListenSpeed.NATURAL,
)

/**
 * One thing said, and what the screen shows meanwhile. An English translation shows the Japanese line it
 * translates, so the screen doesn't flicker between the two.
 */
data class ListenUtterance(
    val text: String,
    val voice: ListenVoice,
    val rate: Float,
    val pauseAfterMillis: Long,
    val japanese: String = "",
    val kana: String = "",
    val english: String = "",
    /** "You", the other person's name, or "Hanaseru" for announcements. */
    val speaker: String = "",
)

data class ListenScene(
    val id: String,
    val title: String,
    val titleJa: String,
    val utterances: List<ListenUtterance>,
)

data class Playlist(
    val options: ListenOptions,
    val scenes: List<ListenScene>,
    /** Said after the last scene. */
    val ending: List<ListenUtterance>,
) {
    val estimatedSeconds: Double
        get() = scenes.sumOf { ListenPlaylist.estimatedSeconds(it.utterances) } + ListenPlaylist.estimatedSeconds(ending)
}

object ListenPlaylist {
    const val MIN_SCENES = 3
    const val MAX_SCENES = 10
    const val RECENT_LIMIT = 30

    const val LINE_PAUSE_MILLIS = 800L
    const val BEFORE_ENGLISH_MILLIS = 400L
    const val SCENE_PAUSE_MILLIS = 2_500L

    /** Previous scene within this long of a scene's start; after it, Previous restarts the scene. */
    const val RESTART_AFTER_MILLIS = 3_000L

    private const val ANNOUNCER = "Hanaseru"

    /**
     * The scenes to play: the chosen source (or everything, when the source has none), shuffled, with scenes heard
     * lately at the back, added until the playlist is long enough (at least 3, at most 10 scenes).
     *
     * `recent` is the ids of scenes played lately, oldest first; `myScenes` the ids of the learner's own scenes.
     */
    fun build(
        library: ContentLibrary,
        options: ListenOptions,
        field: String,
        myScenes: Set<String>,
        learnerName: String,
        recent: List<String>,
        random: Random = Random.Default,
    ): Playlist {
        val playable = library.scenarios.filter { scene -> scene.beats.any { it.responses.isNotEmpty() || it.line.isNotBlank() } }
        val chosen = playable.filter { matches(it, options.source, field, myScenes) }.ifEmpty { playable }
        val ordered = order(chosen, recent, random)

        val scenes = mutableListOf<ListenScene>()
        var seconds = 0.0
        for (scenario in ordered) {
            if (scenes.size >= MAX_SCENES) break
            if (scenes.size >= MIN_SCENES && seconds >= options.length.seconds) break
            val scene = scene(library, scenario, scenes.size + 1, options, learnerName)
            if (scene.utterances.isEmpty()) continue
            scenes.add(scene)
            seconds += estimatedSeconds(scene.utterances)
        }
        return Playlist(options, scenes, ending(options))
    }

    /** Whether a scene belongs to a source. Your own scenes are only in "My scenes" and "Everything". */
    fun matches(scenario: Scenario, source: ListenSource, field: String, myScenes: Set<String>): Boolean = when (source) {
        ListenSource.EVERYTHING -> true
        ListenSource.MY_SCENES -> scenario.id in myScenes
        ListenSource.MY_WORK -> scenario.id !in myScenes && scenario.track == "work" && scenario.workField == field
        // Everyday life, plus "Money in Japan" for someone in finance.
        ListenSource.EVERYDAY -> scenario.id !in myScenes && scenario.track == "everyday" &&
            (scenario.workField == null || scenario.workField == field)
    }

    /** Shuffled, but scenes not heard lately first; the ones heard lately follow, the longest-ago first. */
    fun order(scenes: List<Scenario>, recent: List<String>, random: Random = Random.Default): List<Scenario> {
        val heardAt = recent.withIndex().associate { (index, id) -> id to index }
        val (heard, fresh) = scenes.shuffled(random).partition { it.id in heardAt }
        return fresh + heard.sortedBy { heardAt[it.id] ?: 0 }
    }

    /** The ids played lately after playing one more: it moves to the end, and only the last 30 are kept. */
    fun remember(recent: List<String>, id: String, limit: Int = RECENT_LIMIT): List<String> =
        (recent.filter { it != id } + id).takeLast(limit)

    /** Previous: back to the scene before, or the start of this one when more than ~3 s in (or in the ending). */
    fun previousScene(current: Int, millisIntoScene: Long, sceneCount: Int): Int = when {
        sceneCount == 0 -> 0
        current >= sceneCount -> sceneCount - 1
        millisIntoScene > RESTART_AFTER_MILLIS -> current
        else -> maxOf(0, current - 1)
    }

    /** Japanese characters ÷ 6 a second ÷ rate; English words ÷ 2.5 a second; plus the pauses. */
    fun estimatedSeconds(utterances: List<ListenUtterance>): Double = utterances.sumOf { utterance ->
        val speaking = if (utterance.voice == ListenVoice.ENGLISH) {
            utterance.text.split(Regex("\\s+")).count { it.isNotBlank() } / 2.5
        } else {
            utterance.text.count { !it.isWhitespace() } / 6.0 / utterance.rate
        }
        speaking + utterance.pauseAfterMillis / 1000.0
    }

    /** What is said for one scene: its announcement, then every line of the script in order. */
    fun scene(library: ContentLibrary, scenario: Scenario, number: Int, options: ListenOptions, learnerName: String): ListenScene {
        val both = options.language == ListenLanguage.JAPANESE_ENGLISH
        val rate = options.speed.rate
        val persona = library.persona(scenario.personaID)
        val partnerVoice = if (persona?.isFemale == true) ListenVoice.PARTNER_FEMALE else ListenVoice.PARTNER_MALE
        val partnerName = persona?.nameEn?.ifBlank { null } ?: "Colleague"
        val said = mutableListOf<ListenUtterance>()

        fun english(text: String, japanese: String = "", kana: String = "", speaker: String = ANNOUNCER) {
            if (text.isBlank()) return
            said.add(ListenUtterance(text, ListenVoice.ENGLISH, 1f, LINE_PAUSE_MILLIS, japanese, kana, text, speaker))
        }

        fun line(japanese: String, kana: String, english: String, voice: ListenVoice, speaker: String) {
            val ja = fill(japanese, learnerName)
            if (ja.isBlank()) return
            val ka = fill(kana, learnerName)
            val en = fillEnglish(english, learnerName)
            val withEnglish = both && en.isNotBlank()
            said.add(ListenUtterance(ja, voice, rate, if (withEnglish) BEFORE_ENGLISH_MILLIS else LINE_PAUSE_MILLIS,
                                     ja, ka, en, speaker))
            if (withEnglish) english(en, ja, ka, speaker)
        }

        // The announcement.
        if (both) {
            english("Scene $number: ${scenario.title}.")
            if (scenario.titleJa.isNotBlank()) {
                said.add(ListenUtterance(scenario.titleJa, ListenVoice.COACH_JAPANESE, rate, LINE_PAUSE_MILLIS,
                                         scenario.titleJa, "", scenario.title, ANNOUNCER))
            }
            english(scenario.situationEn)
        } else {
            val text = "場面$number。" + if (scenario.titleJa.isNotBlank()) "${scenario.titleJa}。" else ""
            said.add(ListenUtterance(text, ListenVoice.COACH_JAPANESE, rate, LINE_PAUSE_MILLIS, text, "", scenario.title, ANNOUNCER))
        }

        // The script: the other person's line, your first answer, …, then the closing line.
        for (beat in scenario.beats) {
            line(beat.line, beat.kana, beat.english, partnerVoice, partnerName)
            beat.responses.firstOrNull()?.let { line(it.japanese, it.kana, it.english, ListenVoice.COACH_JAPANESE, "You") }
        }
        line(scenario.closingLine, scenario.closingKana, scenario.closingEnglish, partnerVoice, partnerName)

        // A longer breath before the next scene.
        if (said.isNotEmpty()) said[said.lastIndex] = said.last().copy(pauseAfterMillis = SCENE_PAUSE_MILLIS)
        return ListenScene(scenario.id, scenario.title, scenario.titleJa, said)
    }

    fun ending(options: ListenOptions): List<ListenUtterance> {
        val japanese = "おしまいです。お疲れさまでした。"
        val end = ListenUtterance(japanese, ListenVoice.COACH_JAPANESE, options.speed.rate, LINE_PAUSE_MILLIS, japanese,
                                  "おしまいです。おつかれさまでした。", "That's the end. Well done.", ANNOUNCER)
        if (options.language == ListenLanguage.JAPANESE) return listOf(end)
        val english = "That's the end. Well done."
        return listOf(end.copy(pauseAfterMillis = BEFORE_ENGLISH_MILLIS),
                      ListenUtterance(english, ListenVoice.ENGLISH, 1f, LINE_PAUSE_MILLIS, japanese, end.kana, english, ANNOUNCER))
    }

    /** {name} is the learner's name, or left out when there is none. */
    fun fill(text: String, name: String): String = text.replace("{name}", name.trim())

    /** As [fill], tidying the English a missing name leaves behind ("I'm ." → "I'm."). */
    fun fillEnglish(text: String, name: String): String {
        val filled = fill(text, name)
        if (name.isNotBlank()) return filled
        return filled.replace(Regex(" {2,}"), " ").replace(Regex(" ([.,!?])"), "$1").trim()
    }
}
