package com.swapnil.hanaseru.content

import android.icu.text.BreakIterator
import android.icu.util.ULocale

/** Japanese text split into words by the system's ICU word breaker (no spaces in Japanese). */
object JapaneseWords {
    fun split(text: String): List<String> {
        val iterator = BreakIterator.getWordInstance(ULocale.JAPANESE)
        iterator.setText(text)
        val words = mutableListOf<String>()
        var start = iterator.first()
        var end = iterator.next()
        while (end != BreakIterator.DONE) {
            val word = text.substring(start, end).trim()
            if (word.isNotEmpty()) words.add(word)
            start = end
            end = iterator.next()
        }
        return words
    }
}
