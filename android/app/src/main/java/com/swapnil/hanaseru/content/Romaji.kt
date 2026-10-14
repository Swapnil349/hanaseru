package com.swapnil.hanaseru.content

/**
 * Japanese written in English letters — modified Hepburn with long vowels marked, as in the course content:
 * 「いいえ、特に問題はありません。」 → "Iie, toku ni mondai wa arimasen." (The same rules as the iPhone app.)
 */
object Romaji {
    /** Splits Japanese text into words (the system's ICU word breaker on Android); null in plain unit tests. */
    @Volatile
    var wordSplitter: ((String) -> List<String>)? = null

    private val cache = HashMap<String, String>()

    /**
     * A sentence in romaji, split into words, with particles as they're said (は → wa, へ → e, を → o).
     * `kana` is the reading of `japanese`; it can be empty when `japanese` is all kana. Returns "" when
     * there is no reading (kanji without kana).
     */
    fun of(japanese: String, kana: String): String {
        val key = "$japanese|$kana"
        synchronized(cache) { cache[key]?.let { return it } }
        val result = make(japanese, kana)
        synchronized(cache) { cache[key] = result }
        return result
    }

    internal fun make(japanese: String, kana: String): String {
        val reading = kana.ifEmpty { japanese }
        if (reading.isEmpty() || reading.any(::isKanji)) return ""
        return sentence(words(japanese.ifEmpty { reading }, reading))
    }

    // MARK: Words

    internal data class Piece(val kana: String, val surface: String)

    internal fun words(japanese: String, kana: String): List<String> {
        val splitter = wordSplitter
        if (splitter != null) {
            val aligned = alignedWords(splitter(japanese), kana)
            if (aligned != null) return glue(aligned)
        }
        return glue(fallbackWords(kana).map { Piece(it, it) })
    }

    /** Without a word breaker, words end at punctuation. */
    internal fun fallbackWords(kana: String): List<String> {
        val words = mutableListOf<String>()
        val current = StringBuilder()
        for (character in kana) {
            if (isPunctuation(character) || character == ' ' || character == '　') {
                if (current.isNotEmpty()) words.add(current.toString())
                current.clear()
                if (character != ' ' && character != '　') words.add(character.toString())
            } else {
                current.append(character)
            }
        }
        if (current.isNotEmpty()) words.add(current.toString())
        return words
    }

    /**
     * Words of `kana`, at the word boundaries found in the Japanese. Kana, punctuation and letters appear
     * as they are in the reading; kanji words take the reading up to the next of those. Null when the two
     * can't be lined up.
     */
    internal fun alignedWords(tokens: List<String>, kana: String): List<Piece>? {
        val parts = tokens.flatMap { token ->
            val trimmed = token.trim()
            when {
                trimmed.isEmpty() -> emptyList()
                trimmed.length > 1 && trimmed.all(::isPunctuation) -> trimmed.map { it.toString() }
                else -> listOf(trimmed)
            }
        }
        if (parts.isEmpty()) return null
        val reading = kana.toList()
        val plain = reading.map(::toHiragana)
        var position = 0
        val words = mutableListOf<Piece>()

        fun skipSpaces() {
            while (position < reading.size && (reading[position] == ' ' || reading[position] == '　')) position++
        }

        fun matches(text: String, at: Int): Boolean {
            val wanted = text.map(::toHiragana)
            if (wanted.isEmpty() || at + wanted.size > plain.size) return false
            return plain.subList(at, at + wanted.size) == wanted
        }

        fun find(text: String, from: Int): Int? {
            var index = from
            while (index < plain.size) {
                if (matches(text, index)) return index
                index++
            }
            return null
        }

        var index = 0
        while (index < parts.size) {
            skipSpaces()
            val part = parts[index]
            if (part.none(::isKanji)) {
                if (!matches(part, position)) return null
                words.add(Piece(String(reading.subList(position, position + part.length).toCharArray()), part))
                position += part.length
                index++
                continue
            }
            // A word ending in kana (特に, 近く) ends where that kana is in the reading.
            val trailing = part.takeLastWhile { !isKanji(it) }
            if (trailing.isNotEmpty()) {
                val found = find(trailing, position + 1)
                if (found != null) {
                    val end = found + trailing.length
                    words.add(Piece(String(reading.subList(position, end).toCharArray()), part))
                    position = end
                    index++
                    continue
                }
            }
            var next = index + 1
            while (next < parts.size && parts[next].any(::isKanji)) next++
            val end: Int
            if (next < parts.size) {
                end = find(parts[next], position + 1) ?: return null
            } else {
                end = reading.size
            }
            if (end <= position) return null
            words.add(Piece(String(reading.subList(position, end).toCharArray()), parts.subList(index, next).joinToString("")))
            position = end
            index = next
        }
        skipSpaces()
        if (position < reading.size) {
            val rest = String(reading.subList(position, reading.size).toCharArray())
            words.add(Piece(rest, rest))
        }
        return words
    }

    /** Endings written together with the word before them (ari-masen, okut-te, tanoshikat-ta). */
    private val endings = setOf(
        "ます", "まし", "ませ", "ましょ", "ましょう", "ん", "た", "て", "ない", "なかっ", "なく", "なけれ",
        "たい", "たく", "たかっ", "う", "よう", "れ", "られ", "せ", "させ", "ば", "ちゃ", "ちゃう", "たら", "たり",
        "ず", "ぬ",
    )

    /** Joins endings to their word, and the polite prefixes お／ご to the word after them. */
    internal fun glue(pieces: List<Piece>): List<String> {
        val result = mutableListOf<Piece>()
        var prefix: Piece? = null
        for (piece in pieces) {
            val plain = piece.kana.map(::toHiragana).joinToString("")
            if (plain == "お" || plain == "ご") {
                prefix = Piece((prefix?.kana ?: "") + piece.kana, (prefix?.surface ?: "") + piece.surface)
                continue
            }
            val joined = Piece((prefix?.kana ?: "") + piece.kana, (prefix?.surface ?: "") + piece.surface)
            prefix = null
            val last = result.lastOrNull()
            if (last != null && !isPunctuationWord(last.kana)) {
                val lastPlain = last.kana.map(::toHiragana).joinToString("")
                // で／だ after a verb stem ending in ん is the verb's ending (住んで); otherwise a particle.
                val verbalDe = (plain == "で" || plain == "だ") && last.surface.endsWith("ん") && last.surface.any(::isKanji)
                if (plain in endings || verbalDe || lastPlain.endsWith("っ")) {
                    result[result.size - 1] = Piece(last.kana + joined.kana, last.surface + joined.surface)
                    continue
                }
            }
            result.add(joined)
        }
        prefix?.let { result.add(it) }
        return result.map { it.kana }
    }

    // MARK: Sentence

    internal fun sentence(words: List<String>): String {
        val output = StringBuilder()
        var capitalize = true
        var quoteOpen = false
        for (word in words) {
            if (isPunctuationWord(word)) {
                val mark = punctuation(word[0])
                when (mark) {
                    "\"" -> {
                        if (!quoteOpen && output.isNotEmpty() && !output.endsWith(" ")) output.append(' ')
                        output.append('"')
                        quoteOpen = !quoteOpen
                    }
                    "(" -> {
                        if (output.isNotEmpty() && !output.endsWith(" ")) output.append(' ')
                        output.append('(')
                    }
                    else -> output.append(mark)
                }
                if (mark == "." || mark == "?" || mark == "!") capitalize = true
                continue
            }
            var text = romanize(word)
            if (text.isEmpty()) continue
            if (capitalize) {
                text = text.substring(0, 1).uppercase() + text.substring(1)
                capitalize = false
            }
            val opening = output.endsWith("(") || (quoteOpen && output.endsWith("\""))
            if (output.isNotEmpty() && !output.endsWith(" ") && !opening) output.append(' ')
            output.append(text)
        }
        return output.toString().trim()
    }

    /** One word, with particles as said, including a は that ends a word (では, 実は). */
    internal fun romanize(word: String): String {
        val plain = word.map(::toHiragana).joinToString("")
        return when {
            plain == "は" -> "wa"
            plain == "へ" -> "e"
            plain == "を" -> "o"
            plain.length > 1 && plain.endsWith("は") && isHiragana(word.last()) -> fromKana(word.dropLast(1)) + "wa"
            else -> fromKana(word)
        }
    }

    // MARK: Kana

    /** Kana to romaji, with no word splitting: 「しんかんせん」 → "shinkansen", 「きょう」 → "kyō". */
    fun fromKana(kana: String): String {
        val syllables = mutableListOf<String>()
        val characters = kana.map(::toHiragana)
        var index = 0
        var doubleNext = false
        while (index < characters.size) {
            val character = characters[index]
            if (character == 'っ') {
                doubleNext = true
                index++
                continue
            }
            if (character == 'ー') {
                if (syllables.isNotEmpty()) syllables[syllables.size - 1] = lengthened(syllables.last())
                index++
                continue
            }
            var syllable = base[character]
            if (syllable == null) {
                // Not kana: letters, digits and anything else pass through.
                syllables.add(halfWidth(character).toString())
                doubleNext = false
                index++
                continue
            }
            // Digraphs: きゃ → kya, しゃ → sha, ふぁ → fa, てぃ → ti.
            val small = if (index + 1 < characters.size) smallVowels[characters[index + 1]] else null
            if (small != null) {
                syllable = combine(syllable, small)
                index++
            }
            if (doubleNext) {
                syllable = (if (syllable.startsWith("ch")) "t" else syllable.substring(0, 1)) + syllable
                doubleNext = false
            }
            // Long vowels: おう and おお → ō, うう → ū.
            val last = syllables.lastOrNull()
            if (last != null && isLongVowel(syllable, last)) {
                syllables[syllables.size - 1] = lengthened(last)
                index++
                continue
            }
            syllables.add(syllable)
            index++
        }
        // ん before a vowel or y is written n' (kon'ya, gen'in).
        val output = StringBuilder()
        for ((position, syllable) in syllables.withIndex()) {
            output.append(syllable)
            val next = syllables.getOrNull(position + 1)?.firstOrNull()
            if (syllable == "n" && next != null && next in "aeiouyāēīōū") output.append('\'')
        }
        return output.toString()
    }

    private fun isLongVowel(syllable: String, last: String): Boolean = when (syllable) {
        "u" -> last.endsWith("o") || last.endsWith("u")
        "o" -> last.endsWith("o")
        else -> false
    }

    private val macrons = mapOf('a' to 'ā', 'i' to 'ī', 'u' to 'ū', 'e' to 'ē', 'o' to 'ō')

    private fun lengthened(syllable: String): String {
        val long = syllable.lastOrNull()?.let { macrons[it] } ?: return syllable
        return syllable.dropLast(1) + long
    }

    private fun combine(syllable: String, small: String): String {
        if (small.startsWith("y")) {
            // し, ち and じ drop their i (sha, cha, ja); others keep a y (kya, nyu, ryo).
            if (syllable == "shi" || syllable == "chi" || syllable == "ji") return syllable.dropLast(1) + small.drop(1)
            if (syllable.endsWith("i")) return syllable.dropLast(1) + small
            return syllable + small
        }
        if (syllable == "u") return "w$small"
        val last = syllable.lastOrNull() ?: return small
        return if (last in "aiueo") syllable.dropLast(1) + small else syllable + small
    }

    private val smallVowels = mapOf(
        'ゃ' to "ya", 'ゅ' to "yu", 'ょ' to "yo", 'ぁ' to "a", 'ぃ' to "i", 'ぅ' to "u", 'ぇ' to "e", 'ぉ' to "o", 'ゎ' to "wa",
    )

    private val base = mapOf(
        'あ' to "a", 'い' to "i", 'う' to "u", 'え' to "e", 'お' to "o",
        'か' to "ka", 'き' to "ki", 'く' to "ku", 'け' to "ke", 'こ' to "ko",
        'が' to "ga", 'ぎ' to "gi", 'ぐ' to "gu", 'げ' to "ge", 'ご' to "go",
        'さ' to "sa", 'し' to "shi", 'す' to "su", 'せ' to "se", 'そ' to "so",
        'ざ' to "za", 'じ' to "ji", 'ず' to "zu", 'ぜ' to "ze", 'ぞ' to "zo",
        'た' to "ta", 'ち' to "chi", 'つ' to "tsu", 'て' to "te", 'と' to "to",
        'だ' to "da", 'ぢ' to "ji", 'づ' to "zu", 'で' to "de", 'ど' to "do",
        'な' to "na", 'に' to "ni", 'ぬ' to "nu", 'ね' to "ne", 'の' to "no",
        'は' to "ha", 'ひ' to "hi", 'ふ' to "fu", 'へ' to "he", 'ほ' to "ho",
        'ば' to "ba", 'び' to "bi", 'ぶ' to "bu", 'べ' to "be", 'ぼ' to "bo",
        'ぱ' to "pa", 'ぴ' to "pi", 'ぷ' to "pu", 'ぺ' to "pe", 'ぽ' to "po",
        'ま' to "ma", 'み' to "mi", 'む' to "mu", 'め' to "me", 'も' to "mo",
        'や' to "ya", 'ゆ' to "yu", 'よ' to "yo",
        'ら' to "ra", 'り' to "ri", 'る' to "ru", 'れ' to "re", 'ろ' to "ro",
        'わ' to "wa", 'ゐ' to "i", 'ゑ' to "e", 'を' to "o", 'ん' to "n", 'ゔ' to "vu",
        'ぁ' to "a", 'ぃ' to "i", 'ぅ' to "u", 'ぇ' to "e", 'ぉ' to "o", 'ゃ' to "ya", 'ゅ' to "yu", 'ょ' to "yo", 'ゎ' to "wa",
    )

    // MARK: Characters

    fun toHiragana(character: Char): Char =
        if (character in 'ァ'..'ヶ') (character.code - 0x60).toChar() else character

    private fun isHiragana(character: Char): Boolean = character in 'ぁ'..'ゟ'

    fun isKanji(character: Char): Boolean =
        character in '一'..'鿿' || character in '㐀'..'䶿' || character == '々'

    private const val PUNCTUATION = "、。，．,.？?！!・「」『』（）()…〜~：:"

    private fun isPunctuation(character: Char): Boolean = character in PUNCTUATION

    private fun isPunctuationWord(word: String): Boolean = word.length == 1 && isPunctuation(word[0])

    private fun punctuation(character: Char): String = when (character) {
        '、', '，', ',', '・' -> ","
        '。', '．', '.' -> "."
        '？', '?' -> "?"
        '！', '!' -> "!"
        '「', '」', '『', '』' -> "\""
        '（', '(' -> "("
        '）', ')' -> ")"
        '…' -> "..."
        '〜', '~' -> "~"
        '：', ':' -> ":"
        else -> character.toString()
    }

    /** Full-width letters and digits as ordinary ones. */
    private fun halfWidth(character: Char): Char =
        if (character in '！'..'～') (character.code - 0xFEE0).toChar() else character
}
