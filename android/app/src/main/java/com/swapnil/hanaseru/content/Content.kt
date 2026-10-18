package com.swapnil.hanaseru.content

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

// The lessons, read from the same JSON files as the iPhone app. Only the fields the Android app uses are
// declared; everything else in the files is ignored.

@Serializable
data class Chunk(val ja: String = "", val kana: String = "")

@Serializable
data class ModelLine(
    val japanese: String = "",
    val kana: String = "",
    val english: String = "",
    val chunks: List<Chunk>? = null,
    val noteEn: String? = null,
) {
    /** {name} in a line is the learner's own name. */
    fun personalized(name: String): ModelLine {
        val who = name.ifEmpty { "…" }
        return copy(japanese = japanese.replace("{name}", who), kana = kana.replace("{name}", who),
                    english = english.replace("{name}", who))
    }
}

@Serializable
data class ScenarioBeat(
    val id: String? = null,
    val line: String = "",
    val kana: String = "",
    val english: String = "",
    val cueEn: String? = null,
    val intentEn: String? = null,
    val hintEn: String = "",
    val responses: List<ModelLine> = emptyList(),
)

@Serializable
data class Scenario(
    val id: String,
    val title: String = "",
    val titleJa: String = "",
    val track: String = "work",
    val level: Int = 1,
    val personaID: String = "",
    val situationEn: String = "",
    val placeEn: String? = null,
    val roleReversal: Boolean = false,
    val targetTerms: List<String> = emptyList(),
    val beats: List<ScenarioBeat> = emptyList(),
    val closingLine: String = "",
    val closingKana: String = "",
    val closingEnglish: String = "",
    /** The line of work ("finance"); work scenes without one are railway engineering. */
    val field: String? = null,
) {
    fun beatID(index: Int): String = beats.getOrNull(index)?.id ?: "b${index + 1}"

    /** "engineering" or "finance", or null for everyday life that suits anyone. */
    val workField: String? get() = field ?: if (track == "work") "engineering" else null
}

@Serializable
data class Persona(
    val id: String,
    val nameJa: String = "",
    val nameEn: String = "",
    val role: String = "",
    val speakingRate: Double = 1.0,
    val voiceGender: String? = null,
) {
    val isFemale: Boolean get() = voiceGender == "female"
}

@Serializable
data class PartnerLine(
    val japanese: String = "",
    val kana: String = "",
    val english: String = "",
    val personaID: String? = null,
)

@Serializable
data class ListeningCheck(
    val questionJa: String = "",
    val questionEn: String = "",
    val modelAnswer: String = "",
    val modelAnswerKana: String = "",
    val modelAnswerEn: String = "",
    val topicEn: String? = null,
)

@Serializable
data class LearningItem(
    val id: String,
    val track: String = "work",
    val category: String = "",
    val level: Int = 1,
    val japanese: String = "",
    val kana: String = "",
    val romaji: String = "",
    val english: String = "",
    val cueEn: String? = null,
    val intentEn: String? = null,
    val situationEn: String? = null,
    val noteEn: String? = null,
    val terms: List<String> = emptyList(),
    val acceptableResponses: List<String> = emptyList(),
    val partner: PartnerLine? = null,
    val listening: ListeningCheck? = null,
)

@Serializable
data class VocabularyTerm(
    val id: String,
    val japanese: String = "",
    val kana: String = "",
    val romaji: String = "",
    val english: String = "",
    val categories: List<String> = emptyList(),
    val level: Int = 1,
    val note: String? = null,
    /** Other ways the word appears in lines (conjugated forms, short kana words). */
    val forms: List<String>? = null,
) {
    val letters: String get() = romaji.ifEmpty { Romaji.of(japanese, kana) }
}

@Serializable
data class CoachCue(val ja: String = "", val kana: String = "", val en: String = "")

/** The other person's line before one of the learner's. */
data class PracticePartner(
    val japanese: String,
    val kana: String,
    val english: String,
    val nameJa: String,
    val nameEn: String,
    val isFemale: Boolean,
    val speakingRate: Double,
) {
    val romaji: String get() = Romaji.of(japanese, kana)
}

/** One line the learner says, from a scene or a phrase, with the line before it. */
data class PracticeLine(
    val id: String,
    val japanese: String,
    val kana: String,
    val english: String,
    val cueEn: String,
    val intentEn: String,
    val partner: PracticePartner?,
    val situationEn: String? = null,
    val noteEn: String? = null,
    val authoredRomaji: String = "",
    val references: List<String> = emptyList(),
) {
    val romaji: String get() = authoredRomaji.ifEmpty { Romaji.of(japanese, kana) }
    val isQuestion: Boolean
        get() = japanese.trim().let { it.endsWith("か。") || it.endsWith("か？") || it.endsWith("？") || it.endsWith("?") }
}

/** Everything the app teaches, loaded once. */
/** One word (or set phrase) of a line, with its reading and its meaning in that line. */
@Serializable
data class WordGloss(val ja: String, val kana: String, val en: String) {
    /** The reading in English letters, with particles as they're said (は → wa). */
    val romaji: String
        get() = if (kana.any { Romaji.toHiragana(it) in '\u3041'..'\u309F' }) Romaji.romanize(kana) else kana
}

class ContentLibrary(
    val items: List<LearningItem>,
    val scenarios: List<Scenario>,
    val personas: List<Persona>,
    val vocabulary: List<VocabularyTerm>,
    val cues: Map<String, CoachCue>,
    /** Every line's words with their meanings, by the line's Japanese. */
    val glossary: Map<String, List<WordGloss>> = emptyMap(),
) {
    private val namedLines = glossary.filterKeys { it.contains("{name}") }

    /** The words of a line in order, or empty. A line with the learner's name in it is found whatever the name. */
    fun words(japanese: String): List<WordGloss> {
        glossary[japanese]?.let { return it }
        for ((key, words) in namedLines) {
            val parts = key.split("{name}")
            if (parts.size != 2 || japanese.length < parts[0].length + parts[1].length) continue
            if (!japanese.startsWith(parts[0]) || !japanese.endsWith(parts[1])) continue
            val name = japanese.substring(parts[0].length, japanese.length - parts[1].length)
            if (name.isEmpty()) continue
            return words.map { if (it.ja == "{name}") WordGloss(name, name, it.en) else it }
        }
        return emptyList()
    }

    private val personaByID = personas.associateBy { it.id }
    private val scenarioByID = scenarios.associateBy { it.id }
    private val itemByID = items.associateBy { it.id }
    private val termByID = vocabulary.associateBy { it.id }

    fun persona(id: String): Persona? = personaByID[id]
    fun scenario(id: String): Scenario? = scenarioByID[id]
    fun item(id: String): LearningItem? = itemByID[id]
    fun term(id: String): VocabularyTerm? = termByID[id]
    fun cue(key: String): CoachCue = cues[key] ?: CoachCue(en = key)

    /** Fills a cue's placeholders: {english}, {name}, {title}… */
    fun fill(template: String, values: Map<String, String>): String =
        values.entries.fold(template) { text, (key, value) -> text.replace("{$key}", value) }

    /** The learner's line in each beat of a scene (the first, most typical answer), with the partner's line. */
    fun lines(scenario: Scenario, learnerName: String): List<PracticeLine> {
        val persona = persona(scenario.personaID)
        return scenario.beats.mapIndexedNotNull { index, beat ->
            val first = beat.responses.firstOrNull()?.personalized(learnerName) ?: return@mapIndexedNotNull null
            val partner = if (beat.line.isEmpty()) null else PracticePartner(
                japanese = beat.line, kana = beat.kana, english = beat.english,
                nameJa = persona?.nameJa ?: "", nameEn = persona?.nameEn ?: "",
                isFemale = persona?.isFemale ?: false, speakingRate = persona?.speakingRate ?: 1.0,
            )
            val references = beat.responses.map { it.personalized(learnerName) }
                .flatMap { listOf(it.japanese, it.kana) }.filter { it.isNotEmpty() }.distinct()
            val cue = beat.cueEn ?: ((if (first.japanese.trim().let { it.endsWith("か？") || it.endsWith("？") }) "Ask: " else "Say: ") + first.english)
            PracticeLine(
                id = "${scenario.id}#${scenario.beatID(index)}",
                japanese = first.japanese, kana = first.kana, english = first.english,
                cueEn = cue, intentEn = beat.intentEn ?: beat.hintEn, partner = partner,
                noteEn = first.noteEn, references = references,
            )
        }
    }

    /**
     * The other role of a scene: the colleague's lines (and the closing line), for the learner to say, each
     * after the learner's usual line, which the app says instead.
     */
    fun partnerSideLines(scenario: Scenario, learnerName: String): List<PracticeLine> {
        val result = mutableListOf<PracticeLine>()
        var before: ModelLine? = null
        fun add(id: String, japanese: String, kana: String, english: String) {
            val usual = before?.let {
                PracticePartner(it.japanese, it.kana, it.english, learnerName.ifEmpty { "あなた" },
                                learnerName.ifEmpty { "You" }, isFemale = false, speakingRate = 1.0)
            }
            val cue = (if (japanese.trim().endsWith("？") || japanese.trim().endsWith("か。")) "Ask: " else "Say: ") + english
            result.add(PracticeLine(id = id, japanese = japanese, kana = kana, english = english, cueEn = cue,
                                    intentEn = cue, partner = usual,
                                    references = listOf(japanese, kana).filter { it.isNotEmpty() }.distinct()))
        }
        scenario.beats.forEachIndexed { index, beat ->
            if (beat.line.isNotEmpty()) add("${scenario.id}#${scenario.beatID(index)}~them", beat.line, beat.kana, beat.english)
            before = beat.responses.firstOrNull()?.personalized(learnerName)
        }
        if (scenario.closingLine.isNotEmpty()) {
            add("${scenario.id}#closing~them", scenario.closingLine, scenario.closingKana, scenario.closingEnglish)
        }
        return result
    }

    /** A phrase as a practice line. */
    fun line(item: LearningItem): PracticeLine {
        val partner = item.partner?.let { line ->
            val persona = line.personaID?.let { persona(it) }
            PracticePartner(line.japanese, line.kana, line.english, persona?.nameJa ?: "", persona?.nameEn ?: "",
                            persona?.isFemale ?: false, persona?.speakingRate ?: 1.0)
        }
        val cue = item.cueEn ?: ((if (item.japanese.trim().endsWith("？")) "Ask: " else "Say: ") + item.english)
        return PracticeLine(
            id = item.id, japanese = item.japanese, kana = item.kana, english = item.english,
            cueEn = cue, intentEn = item.intentEn ?: cue, partner = partner, situationEn = item.situationEn,
            noteEn = item.noteEn, authoredRomaji = item.romaji,
            references = (listOf(item.japanese, item.kana) + item.acceptableResponses).filter { it.isNotEmpty() }.distinct(),
        )
    }

    /** The words used in a scene: its target words first, then every listed word in its lines. */
    fun vocabulary(scenario: Scenario): List<VocabularyTerm> {
        val text = buildList {
            add(scenario.closingLine)
            for (beat in scenario.beats) {
                add(beat.line)
                addAll(beat.responses.map { it.japanese })
            }
        }.joinToString(" ")
        return terms(scenario.targetTerms, text)
    }

    /** The words used in a phrase and the line before it. */
    fun vocabulary(item: LearningItem): List<VocabularyTerm> =
        terms(item.terms, listOf(item.japanese, item.partner?.japanese ?: "").joinToString(" "))

    private fun terms(ids: List<String>, text: String): List<VocabularyTerm> {
        val result = ids.mapNotNull { term(it) }.toMutableList()
        for (candidate in vocabulary) {
            if (result.any { it.id == candidate.id }) continue
            val forms = candidate.forms
            if (forms != null && forms.any { it.isNotEmpty() && text.contains(it) }) {
                result.add(candidate)
                continue
            }
            // Kanji spellings, or kana-only words of 3+ characters: short kana would match inside other words.
            val form = candidate.japanese
            val kanaOnly = form == candidate.kana
            if (form.isEmpty() || (kanaOnly && form.length < 3)) continue
            if (text.contains(form)) result.add(candidate)
        }
        return result
    }

    companion object {
        private val json = Json {
            ignoreUnknownKeys = true
            coerceInputValues = true
            isLenient = true
        }

        /** `read` returns the text of a content file, e.g. "scenarios.json". */
        fun load(read: (String) -> String): ContentLibrary = ContentLibrary(
            items = json.decodeFromString(read("phrases.json")),
            scenarios = json.decodeFromString(read("scenarios.json")),
            personas = json.decodeFromString(read("personas.json")),
            vocabulary = json.decodeFromString(read("vocabulary.json")),
            cues = json.decodeFromString(read("cues.json")),
            glossary = json.decodeFromString(read("glossary.json")),
        )
    }
}
