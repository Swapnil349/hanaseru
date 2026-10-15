package com.swapnil.hanaseru.content

/**
 * Comparing what the learner said (as transcribed) with the Japanese expected — the same rules as the
 * iPhone app: punctuation, spaces, full-width letters and katakana/hiragana never count as differences.
 */
object JapaneseText {
    private const val IGNORABLE = "、。，．？！?!,.・「」『』（）()〜~…:：;；\"' 　\n\t"

    fun normalize(text: String): String {
        val builder = StringBuilder()
        for (character in text) {
            var code = character.code
            if (code in 0xFF01..0xFF5E) code -= 0xFEE0
            if (code in 0x30A1..0x30F6) code -= 0x60
            val folded = code.toChar()
            if (folded in IGNORABLE) continue
            builder.append(folded)
        }
        return builder.toString().lowercase()
    }

    /** Character-level similarity in 0…1 (1 − normalised Levenshtein distance). */
    fun similarity(a: String, b: String): Double {
        val x = normalize(a)
        val y = normalize(b)
        if (x.isEmpty() && y.isEmpty()) return 1.0
        if (x.isEmpty() || y.isEmpty()) return 0.0
        var previous = IntArray(y.length + 1) { it }
        var current = IntArray(y.length + 1)
        for (i in 1..x.length) {
            current[0] = i
            for (j in 1..y.length) {
                val cost = if (x[i - 1] == y[j - 1]) 0 else 1
                current[j] = minOf(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            val swap = previous
            previous = current
            current = swap
        }
        return 1.0 - previous[y.length].toDouble() / maxOf(x.length, y.length)
    }

    fun bestSimilarity(text: String, references: List<String>): Double =
        references.maxOfOrNull { similarity(text, it) } ?: 0.0
}
