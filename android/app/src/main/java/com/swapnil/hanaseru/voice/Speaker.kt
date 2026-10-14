package com.swapnil.hanaseru.voice

import android.content.Context
import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Speech through Android's text-to-speech. `speak` returns when the line has been said (or the calling
 * coroutine is cancelled), so lines can be played one after another like a conversation.
 */
class Speaker(context: Context) {
    /** Who is speaking: the coach's Japanese (and your lines), the other person, or English. */
    enum class Voice { COACH_JAPANESE, PARTNER_MALE, PARTNER_FEMALE, ENGLISH }

    private val ready = CompletableDeferred<Boolean>()
    private val pending = ConcurrentHashMap<String, CompletableDeferred<Unit>>()
    private val tts: TextToSpeech = TextToSpeech(context.applicationContext) { status ->
        ready.complete(status == TextToSpeech.SUCCESS)
    }

    init {
        tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {}

            override fun onDone(utteranceId: String?) {
                finish(utteranceId)
            }

            @Deprecated("Deprecated in Java")
            override fun onError(utteranceId: String?) {
                finish(utteranceId)
            }

            override fun onError(utteranceId: String?, errorCode: Int) {
                finish(utteranceId)
            }

            override fun onStop(utteranceId: String?, interrupted: Boolean) {
                finish(utteranceId)
            }
        })
    }

    private fun finish(utteranceId: String?) {
        if (utteranceId != null) pending.remove(utteranceId)?.complete(Unit)
    }

    /** False when the phone has no Japanese voice installed (Settings › Text-to-speech). */
    suspend fun hasJapanese(): Boolean {
        if (!ready.await()) return false
        return tts.isLanguageAvailable(Locale.JAPAN) >= TextToSpeech.LANG_AVAILABLE
    }

    suspend fun speak(text: String, voice: Voice, rate: Float = 1f) {
        if (text.isBlank() || !ready.await()) return
        tts.setLanguage(if (voice == Voice.ENGLISH) Locale.US else Locale.JAPAN)
        // Without a second Japanese voice, the other person is told apart by pitch.
        tts.setPitch(
            when (voice) {
                Voice.PARTNER_MALE -> 0.86f
                Voice.PARTNER_FEMALE -> 1.14f
                else -> 1f
            }
        )
        tts.setSpeechRate(rate)
        val id = UUID.randomUUID().toString()
        val done = CompletableDeferred<Unit>()
        pending[id] = done
        if (tts.speak(text, TextToSpeech.QUEUE_FLUSH, Bundle(), id) != TextToSpeech.SUCCESS) {
            pending.remove(id)
            return
        }
        try {
            // A watchdog: if the engine never says it finished, carry on anyway.
            val expected = (text.length * 400L / rate.coerceAtLeast(0.5f)).toLong() + 4_000L
            withTimeoutOrNull(expected) { done.await() }
        } catch (cancelled: CancellationException) {
            tts.stop()
            throw cancelled
        } finally {
            pending.remove(id)
        }
    }

    fun stop() {
        tts.stop()
        pending.values.forEach { it.complete(Unit) }
        pending.clear()
    }

    fun shutdown() {
        tts.shutdown()
    }
}
