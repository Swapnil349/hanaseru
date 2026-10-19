package com.swapnil.hanaseru.voice

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume

/**
 * One turn of speech through Android's speech recogniser (Japanese, or English for describing a scene). What you
 * say is turned into text and never recorded. Returns "" when nothing was heard.
 *
 * Only one recogniser is ever alive; one that fails at once (busy, or still letting go of the microphone) is
 * tried once more.
 */
class Listener(private val context: Context, private val focus: AudioFocus? = null) {
    private val main = Handler(Looper.getMainLooper())

    /** How one try ended. */
    private class Attempt(val text: String, val error: Int?, val elapsedMillis: Long, val wasReady: Boolean, val heardAnything: Boolean)

    /** The recogniser listening now and how to end its turn. Main thread only. */
    private inner class Turn(val recognizer: SpeechRecognizer, val continuation: CancellableContinuation<Attempt>) {
        val started = SystemClock.elapsedRealtime()
        var best = ""
        var ready = false
        var done = false

        fun finish(text: String, error: Int?) {
            if (done) return
            done = true
            release()
            if (continuation.isActive) {
                continuation.resume(Attempt(text, error, SystemClock.elapsedRealtime() - started, ready, best.isNotEmpty()))
            }
        }

        fun release() {
            if (current === this) current = null
            runCatching { recognizer.destroy() }
        }
    }

    @Volatile private var current: Turn? = null

    val isAvailable: Boolean get() = SpeechRecognizer.isRecognitionAvailable(context)

    suspend fun listen(
        silenceMillis: Long = 1500,
        language: String = "ja-JP",
        maxMillis: Long = 25_000,
        partial: (String) -> Unit = {},
    ): String {
        if (!isAvailable) return ""
        return withContext(Dispatchers.Main) {
            var lastPartial = ""
            val onPartial: (String) -> Unit = { text ->
                lastPartial = text
                partial(text)
            }
            focus?.acquire()
            try {
                withTimeoutOrNull(maxMillis) {
                    val first = listenOnce(silenceMillis, language, onPartial)
                    if (ListenRetry.shouldRetry(first.error, first.elapsedMillis, first.wasReady, first.heardAnything)) {
                        delay(ListenRetry.DELAY_MILLIS)
                        listenOnce(silenceMillis, language, onPartial).text
                    } else {
                        first.text
                    }
                } ?: lastPartial // Out of time: keep what was heard so far.
            } finally {
                focus?.release()
            }
        }
    }

    private suspend fun listenOnce(silenceMillis: Long, language: String, partial: (String) -> Unit): Attempt =
        suspendCancellableCoroutine { continuation ->
            // Never two recognisers at once: the old one would make the new one "busy".
            current?.let { old ->
                if (!old.done) runCatching { old.recognizer.cancel() }
                old.finish(old.best, ListenRetry.CANCELLED)
                old.release()
            }
            val recognizer = SpeechRecognizer.createSpeechRecognizer(context)
            val turn = Turn(recognizer, continuation)
            current = turn
            recognizer.setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) {
                    turn.ready = true
                }

                override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(rmsdB: Float) {}
                override fun onBufferReceived(buffer: ByteArray?) {}
                override fun onEndOfSpeech() {}
                override fun onEvent(eventType: Int, params: Bundle?) {}

                override fun onError(error: Int) {
                    turn.finish(turn.best, error)
                }

                override fun onResults(results: Bundle?) {
                    val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
                    turn.finish(if (text.isNullOrBlank()) turn.best else text, null)
                }

                override fun onPartialResults(partialResults: Bundle?) {
                    val text = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
                    if (!text.isNullOrBlank() && !turn.done) {
                        turn.best = text
                        partial(text)
                    }
                }
            })
            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, language)
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3)
                putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, silenceMillis)
                putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, silenceMillis)
            }
            continuation.invokeOnCancellation {
                // May run on any thread; the recogniser is only touched on the main one.
                main.post {
                    if (!turn.done) {
                        turn.done = true
                        runCatching { recognizer.cancel() }
                        turn.release()
                    }
                }
            }
            try {
                recognizer.startListening(intent)
            } catch (failed: Exception) {
                turn.finish("", ListenRetry.CANCELLED)
            }
        }

    /** Ends the turn listening now with what was heard. Later turns are never touched. */
    fun cancel() {
        val turn = current ?: return
        main.post {
            if (!turn.done) runCatching { turn.recognizer.cancel() }
            turn.finish(turn.best, ListenRetry.CANCELLED)
        }
    }
}
