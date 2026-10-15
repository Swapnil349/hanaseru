package com.swapnil.hanaseru.practice

import com.swapnil.hanaseru.content.ContentLibrary
import com.swapnil.hanaseru.content.JapaneseText
import com.swapnil.hanaseru.content.PracticeLine
import com.swapnil.hanaseru.content.Scenario
import com.swapnil.hanaseru.voice.Listener
import com.swapnil.hanaseru.voice.Speaker
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * A scene practised hands-free, as on the iPhone: the characters act it out (watch), you repeat your lines
 * after the model (practise), then the real conversation. The scene is explained once in English; after
 * that the coach speaks Japanese only and the English is on screen.
 *
 * It keeps its place line by line: pause, ⏮ ↺ ⏭ and the scrubber carry on from the right line.
 */
class ScenePractice(
    private val library: ContentLibrary,
    private val scenario: Scenario,
    private val speaker: Speaker,
    private val listener: Listener,
    private val progress: Progress,
    requestedMode: Mode,
    /** You play the colleague; the app says your usual lines. */
    val playAsPartner: Boolean,
    learnerName: String,
    private val scope: CoroutineScope,
) {
    enum class Mode(val title: String) {
        AUTOMATIC("Automatic"),
        FULL("Full lesson"),
        PRACTISE("Practise my lines"),
        CONVERSATION("Just the conversation"),
        WATCH("Just watch"),
    }

    enum class Activity { SPEAKING, LISTENING, PAUSED, FINISHED }

    /** Who is speaking: the other side, your side (the model of your line, or you), or the coach. */
    enum class Who { OTHER, YOU, COACH }

    sealed interface Segment {
        data object Intro : Segment
        data class Watch(val index: Int) : Segment
        data class Practise(val index: Int) : Segment
        data class Perform(val index: Int) : Segment
        data object Ending : Segment
    }

    /** A point on the scrubber: a line's question or its answer, in one step. */
    data class Stop(val step: String, val line: Int?, val isAnswer: Boolean, val japanese: String) {
        val title: String
            get() = if (line == null) step else "$step · line $line · " + if (isAnswer) "your answer" else "question"
    }

    data class State(
        val step: String = "",
        val activity: Activity = Activity.SPEAKING,
        val speaking: Who? = null,
        /** Your current line, and whether its Japanese is on screen yet. */
        val line: PracticeLine? = null,
        val answerShown: Boolean = true,
        /** The other side's latest line. */
        val otherJapanese: String = "",
        val otherKana: String = "",
        val otherEnglish: String = "",
        val heard: String = "",
        val feedback: String = "",
        val position: Int = 0,
        val turns: Int = 0,
    )

    val persona = library.persona(scenario.personaID)
    val lines: List<PracticeLine> = if (playAsPartner) library.partnerSideLines(scenario, learnerName)
                                    else library.lines(scenario, learnerName)
    val mode: Mode = when (requestedMode) {
        // A scene already practised goes straight to the conversation.
        Mode.AUTOMATIC -> if (lines.any { progress.isKnown(it.id) }) Mode.CONVERSATION else Mode.FULL
        else -> requestedMode
    }
    val segments: List<Segment> = buildList {
        add(Segment.Intro)
        if (mode == Mode.FULL || mode == Mode.PRACTISE || mode == Mode.WATCH) lines.indices.forEach { add(Segment.Watch(it)) }
        if (mode == Mode.FULL || mode == Mode.PRACTISE) lines.indices.forEach { add(Segment.Practise(it)) }
        if (mode != Mode.WATCH) lines.indices.forEach { add(Segment.Perform(it)) }
        add(Segment.Ending)
    }
    private val targets: List<Pair<Int, Boolean>>
    val stops: List<Stop>

    init {
        val targetList = mutableListOf<Pair<Int, Boolean>>()
        val stopList = mutableListOf<Stop>()
        segments.forEachIndexed { position, segment ->
            val index = when (segment) {
                is Segment.Watch -> segment.index
                is Segment.Practise -> segment.index
                is Segment.Perform -> segment.index
                else -> null
            }
            if (index == null) {
                stopList.add(Stop(if (segment == Segment.Intro) "Start" else "End", null, false, ""))
                targetList.add(position to false)
            } else {
                val line = lines[index]
                stopList.add(Stop(stepName(segment), index + 1, false, line.partner?.japanese ?: ""))
                targetList.add(position to false)
                stopList.add(Stop(stepName(segment), index + 1, true, line.japanese))
                targetList.add(position to true)
            }
        }
        targets = targetList
        stops = stopList
    }

    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state

    private var cursor = 0
    private var answerFirst = false
    private var job: Job? = null
    private val full get() = mode == Mode.FULL
    private val otherVoice = if (playAsPartner) Speaker.Voice.PARTNER_MALE
                             else if (persona?.isFemale == true) Speaker.Voice.PARTNER_FEMALE else Speaker.Voice.PARTNER_MALE

    // MARK: Control

    fun start() = launch()

    fun pause() {
        job?.cancel()
        speaker.stop()
        listener.cancel()
        _state.update { it.copy(activity = Activity.PAUSED, speaking = null) }
    }

    /** Carries on from the line that was playing (from its beginning). */
    fun resume() = launch()

    fun togglePause() = if (_state.value.activity == Activity.PAUSED) resume() else pause()

    fun next() {
        cursor = minOf(cursor + 1, segments.size)
        answerFirst = false
        launch()
    }

    fun previous() {
        cursor = maxOf(cursor - 1, 0)
        answerFirst = false
        launch()
    }

    fun again() {
        answerFirst = false
        launch()
    }

    fun seek(stop: Int) {
        val target = targets.getOrNull(stop) ?: return
        cursor = target.first
        answerFirst = target.second
        launch()
    }

    /** Plays a line on request; the session pauses so it can be heard as often as you like. */
    fun hear(text: String, yours: Boolean, slowly: Boolean = false) {
        pause()
        job = scope.launch {
            speaker.speak(text, if (yours) Speaker.Voice.COACH_JAPANESE else otherVoice, if (slowly) 0.7f else 0.9f)
        }
    }

    fun stop() {
        job?.cancel()
        speaker.stop()
        listener.cancel()
    }

    private fun launch() {
        val previous = job
        previous?.cancel()
        speaker.stop()
        listener.cancel()
        job = scope.launch {
            // Never wait long for the last step to wind down.
            if (previous != null) withTimeoutOrNull(1500) { previous.join() }
            run()
        }
    }

    private suspend fun run() {
        _state.update { it.copy(activity = Activity.SPEAKING) }
        while (cursor < segments.size) {
            play(segments[cursor], answerFirst)
            cursor++
            answerFirst = false
        }
        progress.markPractised(scenario.id)
        _state.update { it.copy(activity = Activity.FINISHED, speaking = null, position = stops.size - 1) }
    }

    // MARK: Speaking

    private suspend fun say(text: String, voice: Speaker.Voice, who: Who, rate: Float = 0.95f) {
        _state.update { it.copy(activity = Activity.SPEAKING, speaking = who) }
        speaker.speak(text, voice, rate)
        _state.update { it.copy(speaking = null) }
    }

    /** A coach phrase in Japanese (inside the scene). */
    private suspend fun coach(key: String, values: Map<String, String> = emptyMap()) =
        say(library.fill(library.cue(key).ja, values), Speaker.Voice.COACH_JAPANESE, Who.COACH)

    /** A coach phrase in English (only in the scene's one explanation). */
    private suspend fun coachEnglish(key: String, values: Map<String, String> = emptyMap()) =
        say(library.fill(library.cue(key).en, values), Speaker.Voice.ENGLISH, Who.COACH)

    private suspend fun otherSays(japanese: String, kana: String, english: String) {
        _state.update { it.copy(otherJapanese = japanese, otherKana = kana, otherEnglish = english) }
        say(japanese, otherVoice, Who.OTHER, rate = (persona?.speakingRate?.toFloat() ?: 1f) * 0.92f)
    }

    private suspend fun model(line: PracticeLine, rate: Float = 0.9f) =
        say(line.japanese, Speaker.Voice.COACH_JAPANESE, Who.YOU, rate)

    private fun place(answer: Boolean) {
        val position = targets.indexOfFirst { it.first == cursor && it.second == answer }.takeIf { it >= 0 }
            ?: targets.indexOfFirst { it.first == cursor }.coerceAtLeast(0)
        _state.update { it.copy(position = position) }
    }

    private fun focus(line: PracticeLine, step: String, answerShown: Boolean) {
        _state.update {
            it.copy(line = line, step = step, answerShown = answerShown, heard = "", feedback = "",
                    otherJapanese = line.partner?.japanese ?: "", otherKana = line.partner?.kana ?: "",
                    otherEnglish = line.partner?.english ?: "")
        }
    }

    /** One listen; the heard text goes on screen as it comes. */
    private suspend fun listen(): String {
        _state.update { it.copy(activity = Activity.LISTENING, speaking = Who.YOU, heard = "") }
        val heard = listener.listen { partial -> _state.update { it.copy(heard = partial) } }
        _state.update { it.copy(activity = Activity.SPEAKING, speaking = null, heard = heard) }
        return heard
    }

    /** Repeat after the model once. Never failed, never retried. */
    private suspend fun echo(line: PracticeLine) {
        val heard = listen()
        val close = heard.isNotEmpty() && JapaneseText.bestSimilarity(heard, line.references) >= 0.7
        _state.update { it.copy(feedback = if (heard.isEmpty()) "" else if (close) "✓ Clearly said" else "Heard: $heard") }
    }

    // MARK: Segments

    private fun stepName(segment: Segment): String = when (segment) {
        is Segment.Watch -> "Watch"
        is Segment.Practise -> "Practise"
        is Segment.Perform -> "Conversation"
        Segment.Intro -> "Start"
        Segment.Ending -> "End"
    }

    private suspend fun play(segment: Segment, fromAnswer: Boolean) {
        place(fromAnswer)
        when (segment) {
            Segment.Intro -> {
                _state.update { it.copy(step = scenario.title, line = null) }
                coachEnglish("sceneIntro", mapOf("title" to scenario.title))
                if (playAsPartner) say("This time you play ${persona?.nameEn ?: "the colleague"}.", Speaker.Voice.ENGLISH, Who.COACH)
                if (full) {
                    say(scenario.situationEn, Speaker.Voice.ENGLISH, Who.COACH)
                    coachEnglish("sceneSteps")
                }
            }

            is Segment.Watch -> {
                val line = lines[segment.index]
                focus(line, if (full) "Step 1 of 3 · Watch the conversation" else "Watch the conversation", true)
                if (!fromAnswer) {
                    if (segment.index == 0) coach(if (full) "listenFirst" else "watchScene")
                    line.partner?.let { otherSays(it.japanese, it.kana, it.english) }
                }
                place(true)
                model(line, 0.95f)
                delay(600)
            }

            is Segment.Practise -> {
                val line = lines[segment.index]
                focus(line, if (full) "Step 2 of 3 · Practise your lines" else "Practise your lines", true)
                if (!fromAnswer) {
                    if (segment.index == 0) coach(if (full) "rehearseStart" else "rehearseShort")
                    line.partner?.let { otherSays(it.japanese, it.kana, it.english) }
                }
                place(true)
                coach(if (line.isQuestion) "ask" else "youSay")
                model(line, 0.85f)
                echo(line)
            }

            is Segment.Perform -> {
                val line = lines[segment.index]
                // While you're learning a line its Japanese is on screen; once you know it, it's hidden.
                val known = progress.isKnown(line.id)
                focus(line, if (full) "Step 3 of 3 · The real conversation" else "The conversation", full || !known)
                if (fromAnswer) {
                    _state.update { it.copy(answerShown = true) }
                    coach("youCouldSay")
                    model(line, 0.85f)
                    echo(line)
                    return
                }
                if (segment.index == 0) {
                    val youStart = lines[0].partner == null
                    if (full) coach(if (youStart) "performYouStart" else "performStart", mapOf("name" to (persona?.nameEn ?: "")))
                    else coach(if (youStart) "goYouShort" else "goShort", mapOf("name" to (persona?.nameEn ?: "")))
                }
                line.partner?.let { otherSays(it.japanese, it.kana, it.english) }
                place(true)
                val heard = listen()
                val similarity = if (heard.isEmpty()) 0.0 else JapaneseText.bestSimilarity(heard, line.references)
                if (similarity >= 0.75) {
                    progress.markKnown(line.id)
                    _state.update { it.copy(feedback = "✓ Nice", answerShown = true) }
                    delay(500)
                } else {
                    _state.update {
                        it.copy(answerShown = true,
                                feedback = if (heard.isEmpty()) "Here's how to say it" else "Close. Here's how to say it")
                    }
                    coach("youCouldSay")
                    model(line, 0.85f)
                    echo(line)
                }
                _state.update { it.copy(turns = it.turns + 1) }
            }

            Segment.Ending -> {
                _state.update { it.copy(step = "End", line = null) }
                // Playing the colleague, the closing line was your own last line.
                if (!playAsPartner && scenario.closingLine.isNotEmpty()) {
                    otherSays(scenario.closingLine, scenario.closingKana, scenario.closingEnglish)
                }
                coach("conversationEnd")
            }
        }
    }
}
