package com.swapnil.hanaseru.voice

/**
 * When a spoken line didn't really happen. Text-to-speech engines can report success and stay silent, finish a
 * line in a few milliseconds, or never start it; these checks decide when to say a line once more.
 */
object SpeechTiming {
    /** How long a line may take to start before the engine is thought to have lost it. */
    const val START_GRACE_MILLIS = 2_000L

    /** The second try waits longer: the engine may have just been restarted. */
    const val RETRY_START_GRACE_MILLIS = 4_000L

    /** How long to wait for the engine to come up. */
    const val READY_MILLIS = 5_000L

    /** The line ended without the engine ever saying it started. */
    const val NO_START = -1L

    /** How one try at a line ended, as the engine reported it. */
    enum class End { DONE, ERROR, STOPPED }

    /** What to make of a try. */
    enum class Verdict {
        /** Said, as far as anyone can tell. */
        SPOKEN,

        /** Stopped on purpose (paused, or another line took its place): never said again. */
        STOPPED,

        /** The engine took the line and never started it. */
        NEVER_STARTED,

        /** "Finished" far faster than the words could be said: nothing was heard. */
        TOO_FAST,

        /** Another app took the sound while it was being said. */
        INTERRUPTED,

        /** The engine reported an error for the line. */
        FAILED,

        /** The engine isn't working (didn't start up, or refused the line). */
        ENGINE_FAILED,
    }

    /**
     * Roughly how long a line takes to say at this rate: about 8 kana a second in Japanese, 14 letters a second in
     * English. Punctuation and spaces count for nothing, so this errs on the short side.
     */
    fun expectedMillis(text: String, rate: Float): Long {
        var millis = 0.0
        for (character in text) {
            millis += when {
                !character.isLetterOrDigit() -> 0.0
                character.code < 0x3000 -> 70.0
                else -> 125.0
            }
        }
        return (millis / rate.coerceIn(0.3f, 3f)).toLong()
    }

    /** Finishing faster than this means nothing was said. Short lines ("はい") are never judged. */
    fun minimumMillis(text: String, rate: Float): Long {
        val expected = expectedMillis(text, rate)
        return if (expected < 1_000L) 0L else expected / 4
    }

    /** A watchdog: if the engine never says it finished, carry on after this long. */
    fun watchdogMillis(text: String, rate: Float): Long = expectedMillis(text, rate) * 3 + 4_000L

    /** `spokenMillis` is from the line's start (or, without one, from asking for it) to its end. */
    fun verdict(end: End, spokenMillis: Long, text: String, rate: Float, interrupted: Boolean): Verdict = when {
        end == End.STOPPED -> Verdict.STOPPED
        interrupted -> Verdict.INTERRUPTED
        end == End.ERROR -> Verdict.FAILED
        spokenMillis < minimumMillis(text, rate) -> Verdict.TOO_FAST
        else -> Verdict.SPOKEN
    }

    /** Whether a failed try is worth a second one. */
    fun shouldRetry(verdict: Verdict): Boolean = verdict != Verdict.SPOKEN && verdict != Verdict.STOPPED

    /** Whether the engine should be restarted before the second try. */
    fun needsRestart(verdict: Verdict): Boolean = verdict == Verdict.ENGINE_FAILED || verdict == Verdict.NEVER_STARTED
}

/**
 * When a turn of listening ended before it began. Android's recogniser, started again quickly, often fails at once
 * ("busy", "client error", or "no match" before it was even ready); one more try after a short pause usually works.
 */
object ListenRetry {
    /** The listening was cancelled on purpose. */
    const val CANCELLED = -1

    /** The pause before trying again, so the last recogniser has fully let go of the microphone. */
    const val DELAY_MILLIS = 400L

    // SpeechRecognizer's error codes (the last needs Android 12 for its name, not its value).
    private const val ERROR_CLIENT = 5
    private const val ERROR_SPEECH_TIMEOUT = 6
    private const val ERROR_NO_MATCH = 7
    private const val ERROR_RECOGNIZER_BUSY = 8
    private const val ERROR_SERVER_DISCONNECTED = 11

    /** A failure this soon after starting, before the recogniser was ready, wasn't you saying nothing. */
    private const val TOO_SOON_MILLIS = 1_000L

    fun shouldRetry(error: Int?, elapsedMillis: Long, wasReady: Boolean, heardAnything: Boolean): Boolean {
        if (error == null || error == CANCELLED || heardAnything) return false
        return when (error) {
            ERROR_RECOGNIZER_BUSY, ERROR_CLIENT, ERROR_SERVER_DISCONNECTED -> true
            ERROR_NO_MATCH, ERROR_SPEECH_TIMEOUT -> !wasReady && elapsedMillis < TOO_SOON_MILLIS
            else -> false
        }
    }
}
