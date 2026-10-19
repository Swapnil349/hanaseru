package com.swapnil.hanaseru.voice

import com.swapnil.hanaseru.voice.SpeechTiming.End
import com.swapnil.hanaseru.voice.SpeechTiming.Verdict
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SpeechChecksTest {
    private val line = "おはようございます。今日はよろしくお願いします。"

    @Test
    fun aLineTakesTimeToSay() {
        val normal = SpeechTiming.expectedMillis(line, 1f)
        assertTrue(normal in 2_000L..4_000L)
        // Slower speech takes longer; punctuation takes nothing.
        assertTrue(SpeechTiming.expectedMillis(line, 0.7f) > normal)
        assertEquals(0L, SpeechTiming.expectedMillis("。、！？ ", 1f))
        assertTrue(SpeechTiming.watchdogMillis(line, 1f) > normal + 3_000L)
    }

    @Test
    fun aLineThatFinishesAtOnceWasNotHeard() {
        assertEquals(Verdict.TOO_FAST, SpeechTiming.verdict(End.DONE, 40, line, 1f, interrupted = false))
        assertEquals(Verdict.SPOKEN, SpeechTiming.verdict(End.DONE, 2_600, line, 1f, interrupted = false))
        // Short lines are never judged: はい can really be said in a moment.
        assertEquals(Verdict.SPOKEN, SpeechTiming.verdict(End.DONE, 30, "はい。", 1f, interrupted = false))
    }

    @Test
    fun stoppingOnPurposeIsNeverRepeated() {
        val verdict = SpeechTiming.verdict(End.STOPPED, 10, line, 1f, interrupted = true)
        assertEquals(Verdict.STOPPED, verdict)
        assertFalse(SpeechTiming.shouldRetry(verdict))
        assertFalse(SpeechTiming.shouldRetry(Verdict.SPOKEN))
    }

    @Test
    fun failuresAreSaidOnceMore() {
        assertEquals(Verdict.INTERRUPTED, SpeechTiming.verdict(End.DONE, 2_600, line, 1f, interrupted = true))
        assertEquals(Verdict.FAILED, SpeechTiming.verdict(End.ERROR, 2_600, line, 1f, interrupted = false))
        for (verdict in listOf(Verdict.NEVER_STARTED, Verdict.TOO_FAST, Verdict.INTERRUPTED, Verdict.FAILED, Verdict.ENGINE_FAILED)) {
            assertTrue(verdict.name, SpeechTiming.shouldRetry(verdict))
        }
        // Only a dead or silent engine is restarted first.
        assertTrue(SpeechTiming.needsRestart(Verdict.NEVER_STARTED))
        assertTrue(SpeechTiming.needsRestart(Verdict.ENGINE_FAILED))
        assertFalse(SpeechTiming.needsRestart(Verdict.TOO_FAST))
        assertFalse(SpeechTiming.needsRestart(Verdict.INTERRUPTED))
    }

    @Test
    fun aBusyRecogniserIsTriedAgain() {
        assertTrue(ListenRetry.shouldRetry(8, 50, wasReady = false, heardAnything = false)) // busy
        assertTrue(ListenRetry.shouldRetry(5, 50, wasReady = false, heardAnything = false)) // client
        // "No match" at once, before it was ready, wasn't you saying nothing.
        assertTrue(ListenRetry.shouldRetry(7, 200, wasReady = false, heardAnything = false))
        assertFalse(ListenRetry.shouldRetry(7, 6_000, wasReady = true, heardAnything = false))
        assertFalse(ListenRetry.shouldRetry(6, 5_000, wasReady = true, heardAnything = false))
        // Never after hearing something, after a cancel, or after a result.
        assertFalse(ListenRetry.shouldRetry(8, 50, wasReady = false, heardAnything = true))
        assertFalse(ListenRetry.shouldRetry(ListenRetry.CANCELLED, 50, wasReady = false, heardAnything = false))
        assertFalse(ListenRetry.shouldRetry(null, 50, wasReady = true, heardAnything = false))
    }
}
