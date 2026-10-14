package com.swapnil.hanaseru.content

import com.swapnil.hanaseru.voice.Speaker

/** One line of a scene's script, with its reading, meaning and voice. */
data class ScriptEntry(
    val id: String,
    val speaker: String,
    val isLearner: Boolean,
    val japanese: String,
    val kana: String,
    val romaji: String,
    val english: String,
    val voice: Speaker.Voice,
    /** The learner's lines: their place in the scene. */
    val line: Int? = null,
)

/** A scene's complete script: each line of the other person and your answer, then the closing line. */
fun ContentLibrary.script(scenario: Scenario, learnerName: String): List<ScriptEntry> {
    val persona = persona(scenario.personaID)
    val name = persona?.nameEn?.ifEmpty { null } ?: "Colleague"
    val partnerVoice = if (persona?.isFemale == true) Speaker.Voice.PARTNER_FEMALE else Speaker.Voice.PARTNER_MALE
    val entries = mutableListOf<ScriptEntry>()
    lines(scenario, learnerName).forEachIndexed { index, line ->
        line.partner?.let { partner ->
            entries.add(ScriptEntry("p|${line.id}", name, false, partner.japanese, partner.kana, partner.romaji,
                                    partner.english, partnerVoice))
        }
        entries.add(ScriptEntry(line.id, "You", true, line.japanese, line.kana, line.romaji, line.english,
                                Speaker.Voice.COACH_JAPANESE, index))
    }
    if (scenario.closingLine.isNotEmpty()) {
        entries.add(ScriptEntry("closing", name, false, scenario.closingLine, scenario.closingKana,
                                Romaji.of(scenario.closingLine, scenario.closingKana), scenario.closingEnglish, partnerVoice))
    }
    return entries
}

/** The script as text in three ways — Japanese (with its kana), English letters and English — to share. */
fun scriptText(title: String, situation: String, entries: List<ScriptEntry>): String = buildString {
    appendLine(title)
    if (situation.isNotEmpty()) appendLine(situation)
    for (entry in entries) {
        appendLine()
        appendLine("${entry.speaker}:")
        appendLine("  ${entry.japanese}")
        if (entry.kana.isNotEmpty() && entry.kana != entry.japanese) appendLine("  ${entry.kana}")
        if (entry.romaji.isNotEmpty()) appendLine("  ${entry.romaji}")
        if (entry.english.isNotEmpty()) appendLine("  ${entry.english}")
    }
}
