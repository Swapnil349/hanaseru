package com.swapnil.hanaseru.voice

import android.content.Context
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Bundle
import android.os.SystemClock
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import com.swapnil.hanaseru.voice.SpeechTiming.End
import com.swapnil.hanaseru.voice.SpeechTiming.Verdict
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Speech through Android's text-to-speech. `speak` returns when the line has been said (or the calling
 * coroutine is cancelled), so lines can be played one after another like a conversation.
 *
 * It makes sure a line is heard: a line the engine never starts, or "finishes" too fast to have been said, or that
 * another app talked over, is said once more (restarting the engine when it has died). Nothing waits for ever.
 */
class Speaker(context: Context, private val focus: AudioFocus = AudioFocus(context)) {
    /** Who is speaking: the coach's Japanese (and your lines), the other person, or English. */
    enum class Voice { COACH_JAPANESE, PARTNER_MALE, PARTNER_FEMALE, ENGLISH }

    /** One try at a line. */
    private class Utterance(val id: String) {
        /** When it started, or NO_START if it ended without starting. */
        val started = CompletableDeferred<Long>()
        val ended = CompletableDeferred<Pair<End, Long>>()
        @Volatile var interrupted = false
    }

    private val appContext = context.applicationContext
    private val pending = ConcurrentHashMap<String, Utterance>()

    /** The line being said now. Only its own speaker may stop it, so a cancelled line can't silence the next one. */
    @Volatile private var currentID: String? = null
    @Volatile private var ready = CompletableDeferred<Boolean>()
    private var lastRestart = 0L

    /**
     * Called (on the main thread) when another app takes the sound for good, or a phone call holds it: a practice
     * session pauses here instead of talking over it. Without one, the line is simply said again afterwards.
     */
    var onFocusLost: (() -> Unit)? = null

    private val progress = object : UtteranceProgressListener() {
        override fun onStart(utteranceId: String?) {
            utteranceId?.let { pending[it] }?.started?.complete(SystemClock.elapsedRealtime())
        }

        override fun onDone(utteranceId: String?) {
            end(utteranceId, End.DONE)
        }

        @Deprecated("Deprecated in Java")
        override fun onError(utteranceId: String?) {
            end(utteranceId, End.ERROR)
        }

        override fun onError(utteranceId: String?, errorCode: Int) {
            end(utteranceId, End.ERROR)
        }

        override fun onStop(utteranceId: String?, interrupted: Boolean) {
            end(utteranceId, End.STOPPED)
        }
    }

    @Volatile private var tts: TextToSpeech = create()

    init {
        focus.onChange = { change -> focusChanged(change) }
    }

    /** A new engine; its own readiness signal, so a late answer from an old engine can't confuse it. */
    private fun create(): TextToSpeech {
        val signal = CompletableDeferred<Boolean>()
        ready = signal
        val engine = TextToSpeech(appContext) { status -> signal.complete(status == TextToSpeech.SUCCESS) }
        engine.setOnUtteranceProgressListener(progress)
        engine.setAudioAttributes(AudioFocus.ATTRIBUTES)
        return engine
    }

    /** Shuts a dead or silent engine and starts a fresh one (at most every few seconds). */
    private fun restart() {
        val now = SystemClock.elapsedRealtime()
        if (lastRestart != 0L && now - lastRestart < RESTART_GAP_MILLIS) return
        lastRestart = now
        val old = tts
        runCatching { old.stop() }
        runCatching { old.shutdown() }
        tts = create()
    }

    private fun end(utteranceId: String?, how: End) {
        val utterance = utteranceId?.let { pending[it] } ?: return
        val now = SystemClock.elapsedRealtime()
        utterance.started.complete(SpeechTiming.NO_START)
        utterance.ended.complete(how to now)
    }

    private fun focusChanged(change: Int) {
        // Only matters while a line is being said; while listening, the recogniser itself may take the sound.
        val utterance = currentID?.let { pending[it] } ?: return
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS -> {
                val handler = onFocusLost
                if (handler != null) {
                    handler()
                } else {
                    utterance.interrupted = true
                }
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                utterance.interrupted = true
            }
        }
    }

    private suspend fun awaitReady(): Boolean = withTimeoutOrNull(SpeechTiming.READY_MILLIS) { ready.await() } ?: false

    /** False when the phone has no Japanese voice installed (Settings › Text-to-speech). */
    suspend fun hasJapanese(): Boolean = withContext(Dispatchers.Main.immediate) {
        if (!awaitReady()) {
            restart()
            if (!awaitReady()) return@withContext false
        }
        tts.isLanguageAvailable(Locale.JAPAN) >= TextToSpeech.LANG_AVAILABLE
    }

    /** True when media volume is all the way down. */
    val isMuted: Boolean get() = focus.isMuted

    suspend fun speak(text: String, voice: Voice, rate: Float = 1f) {
        if (text.isBlank()) return
        withContext<Unit>(Dispatchers.Main.immediate) {
            val granted = focus.acquire()
            try {
                if (!granted) {
                    // A phone call has the sound: a session pauses rather than talk over it.
                    val handler = onFocusLost
                    if (handler != null) {
                        handler()
                        return@withContext
                    }
                }
                val first = attempt(text, voice, rate, SpeechTiming.START_GRACE_MILLIS)
                if (!SpeechTiming.shouldRetry(first)) return@withContext
                ensureActive()
                if (SpeechTiming.needsRestart(first)) restart()
                if (first == Verdict.INTERRUPTED && !waitForFocus()) {
                    val handler = onFocusLost
                    if (handler != null) {
                        handler()
                        return@withContext
                    }
                }
                attempt(text, voice, rate, SpeechTiming.RETRY_START_GRACE_MILLIS)
            } finally {
                focus.release()
            }
        }
    }

    /** Waits a little for the sound to come back after another app had it. */
    private suspend fun waitForFocus(): Boolean = withTimeoutOrNull(FOCUS_WAIT_MILLIS) {
        while (!focus.isHeld && !focus.regain()) delay(250)
        true
    } ?: false

    private suspend fun attempt(text: String, voice: Voice, rate: Float, startGrace: Long): Verdict {
        if (!awaitReady()) return Verdict.ENGINE_FAILED
        val engine = tts
        engine.setLanguage(if (voice == Voice.ENGLISH) Locale.US else Locale.JAPAN)
        // Without a second Japanese voice, the other person is told apart by pitch.
        engine.setPitch(
            when (voice) {
                Voice.PARTNER_MALE -> 0.86f
                Voice.PARTNER_FEMALE -> 1.14f
                else -> 1f
            }
        )
        engine.setSpeechRate(rate)
        val utterance = Utterance(UUID.randomUUID().toString())
        pending[utterance.id] = utterance
        currentID = utterance.id
        val asked = SystemClock.elapsedRealtime()
        try {
            if (engine.speak(text, TextToSpeech.QUEUE_FLUSH, Bundle(), utterance.id) != TextToSpeech.SUCCESS) {
                return Verdict.ENGINE_FAILED
            }
            val startedAt: Long = withTimeoutOrNull(startGrace) { utterance.started.await() } ?: run {
                // No start yet. If the engine is talking, only its callbacks are late; otherwise it lost the line.
                if (!runCatching { engine.isSpeaking }.getOrDefault(false)) {
                    if (currentID == utterance.id) engine.stop()
                    return Verdict.NEVER_STARTED
                }
                SpeechTiming.NO_START
            }
            val ended = withTimeoutOrNull(SpeechTiming.watchdogMillis(text, rate)) { utterance.ended.await() }
            if (ended == null) {
                // A watchdog: the engine never said it finished. Carry on, without talking over what comes next.
                if (currentID == utterance.id) engine.stop()
                return Verdict.SPOKEN
            }
            val from = if (startedAt == SpeechTiming.NO_START) asked else startedAt
            return SpeechTiming.verdict(ended.first, ended.second - from, text, rate, utterance.interrupted)
        } catch (cancelled: CancellationException) {
            // Stop this line only: if a newer line has started meanwhile, it keeps playing.
            if (currentID == utterance.id) engine.stop()
            throw cancelled
        } finally {
            pending.remove(utterance.id)
            if (currentID == utterance.id) currentID = null
        }
    }

    /** A short tone: your turn to speak. */
    suspend fun chime() {
        withContext(Dispatchers.Main.immediate) {
            val tone = runCatching { ToneGenerator(AudioManager.STREAM_MUSIC, 70) }.getOrNull() ?: return@withContext
            try {
                tone.startTone(ToneGenerator.TONE_PROP_BEEP, 120)
                delay(220)
            } finally {
                tone.release()
            }
        }
    }

    /** Stops whatever is being said, for everyone (the app going to the background). */
    fun stop() {
        currentID = null
        runCatching { tts.stop() }
        val now = SystemClock.elapsedRealtime()
        pending.values.forEach {
            it.started.complete(SpeechTiming.NO_START)
            it.ended.complete(End.STOPPED to now)
        }
    }

    fun shutdown() {
        runCatching { tts.shutdown() }
    }

    private companion object {
        const val RESTART_GAP_MILLIS = 5_000L
        const val FOCUS_WAIT_MILLIS = 8_000L
    }
}
