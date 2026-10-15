package com.swapnil.hanaseru.voice

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume

/**
 * One turn of Japanese through Android's speech recogniser. What you say is turned into text and never
 * recorded. Returns "" when nothing was heard.
 */
class Listener(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())
    private var current: SpeechRecognizer? = null

    val isAvailable: Boolean get() = SpeechRecognizer.isRecognitionAvailable(context)

    suspend fun listen(silenceMillis: Long = 1500, partial: (String) -> Unit = {}): String {
        if (!isAvailable) return ""
        return withContext(Dispatchers.Main) {
            withTimeoutOrNull(25_000) { listenOnce(silenceMillis, partial) } ?: ""
        }
    }

    private suspend fun listenOnce(silenceMillis: Long, partial: (String) -> Unit): String =
        suspendCancellableCoroutine { continuation ->
            val recognizer = SpeechRecognizer.createSpeechRecognizer(context)
            current = recognizer
            var best = ""
            var done = false
            fun finish(text: String) {
                if (done) return
                done = true
                main.post {
                    recognizer.destroy()
                    if (current === recognizer) current = null
                }
                if (continuation.isActive) continuation.resume(text)
            }
            recognizer.setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) {}
                override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(rmsdB: Float) {}
                override fun onBufferReceived(buffer: ByteArray?) {}
                override fun onEndOfSpeech() {}
                override fun onEvent(eventType: Int, params: Bundle?) {}

                override fun onError(error: Int) {
                    finish(best)
                }

                override fun onResults(results: Bundle?) {
                    val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
                    finish(text ?: best)
                }

                override fun onPartialResults(partialResults: Bundle?) {
                    val text = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
                    if (!text.isNullOrBlank()) {
                        best = text
                        partial(text)
                    }
                }
            })
            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, "ja-JP")
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, "ja-JP")
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3)
                putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, silenceMillis)
                putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, silenceMillis)
            }
            continuation.invokeOnCancellation {
                if (!done) {
                    done = true
                    main.post {
                        recognizer.cancel()
                        recognizer.destroy()
                        if (current === recognizer) current = null
                    }
                }
            }
            recognizer.startListening(intent)
        }

    fun cancel() {
        main.post { current?.cancel() }
    }
}
