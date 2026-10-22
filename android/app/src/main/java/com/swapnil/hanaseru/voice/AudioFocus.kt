package com.swapnil.hanaseru.voice

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Handler
import android.os.Looper

/**
 * The phone's sound, held while the coach speaks or listens, so music and other apps pause instead of playing over
 * (or ducking) the lesson. It is kept for a moment between lines and given back once practice stops. Main thread only.
 *
 * Practice asks for it for a short while (AUDIOFOCUS_GAIN_TRANSIENT); Listen, which plays for many minutes, asks
 * for it outright (AUDIOFOCUS_GAIN).
 */
class AudioFocus(context: Context, gain: Int = AudioManager.AUDIOFOCUS_GAIN_TRANSIENT) {
    private val audio = context.applicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val main = Handler(Looper.getMainLooper())
    private var users = 0

    /** True while this app has the sound (ducked under a notification still counts). */
    var isHeld = false
        private set

    /** Told of every change, e.g. AudioManager.AUDIOFOCUS_LOSS. */
    var onChange: ((Int) -> Unit)? = null

    private val request = AudioFocusRequest.Builder(gain)
        .setAudioAttributes(ATTRIBUTES)
        .setWillPauseWhenDucked(false)
        .setOnAudioFocusChangeListener({ change -> changed(change) }, main)
        .build()

    private val abandon = Runnable {
        if (users == 0) {
            audio.abandonAudioFocusRequest(request)
            isHeld = false
        }
    }

    private fun changed(change: Int) {
        when (change) {
            AudioManager.AUDIOFOCUS_GAIN -> isHeld = true
            AudioManager.AUDIOFOCUS_LOSS, AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> isHeld = false
        }
        onChange?.invoke(change)
    }

    /** Takes the sound for a line or a turn. False only when another app refuses it (a phone call). Pair with release. */
    fun acquire(): Boolean {
        users++
        main.removeCallbacks(abandon)
        return isHeld || regain()
    }

    /** Asks for the sound again, e.g. after another app had it. */
    fun regain(): Boolean {
        val result = audio.requestAudioFocus(request)
        isHeld = result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        return result != AudioManager.AUDIOFOCUS_REQUEST_FAILED
    }

    fun release() {
        users = maxOf(0, users - 1)
        if (users == 0) {
            main.removeCallbacks(abandon)
            main.postDelayed(abandon, HOLD_MILLIS)
        }
    }

    /** True when media volume is all the way down, so nothing the coach says can be heard. */
    val isMuted: Boolean get() = audio.getStreamVolume(AudioManager.STREAM_MUSIC) == 0

    companion object {
        /** Speech on the media volume. */
        val ATTRIBUTES: AudioAttributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()

        /** Long enough to carry the sound from one line (or turn) to the next. */
        const val HOLD_MILLIS = 2_500L
    }
}
