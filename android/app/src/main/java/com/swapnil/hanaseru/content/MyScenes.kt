package com.swapnil.hanaseru.content

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull
import java.time.Instant
import java.util.UUID

// The learner's own scenes, written by the AI coach (docs/MY-SCENES.md). The same JSON on every platform, so a
// scene exported from the iPhone or Windows app imports here unchanged.

/** A time as milliseconds since 1970, as the other apps write it; an ISO-8601 date reads too. */
object TimeMillisSerializer : KSerializer<Long> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor("TimeMillis", PrimitiveKind.LONG)

    override fun serialize(encoder: Encoder, value: Long) = encoder.encodeLong(value)

    override fun deserialize(decoder: Decoder): Long {
        val json = decoder as? JsonDecoder ?: return decoder.decodeLong()
        val primitive = json.decodeJsonElement() as? JsonPrimitive ?: return 0L
        primitive.longOrNull?.let { return it }
        primitive.doubleOrNull?.let { return it.toLong() }
        return runCatching { Instant.parse(primitive.content).toEpochMilli() }.getOrDefault(0L)
    }
}

@Serializable
data class SceneWord(val ja: String = "", val kana: String = "", val en: String = "")

/** One line of a written scene. In a speech the other person's lines are all empty. */
@Serializable
data class SceneLine(
    val japanese: String = "",
    val kana: String = "",
    val english: String = "",
    val words: List<SceneWord> = emptyList(),
)

@Serializable
data class SceneResultBeat(
    val partner: SceneLine = SceneLine(),
    val learner: SceneLine = SceneLine(),
    val hintEn: String = "",
)

/** The coach's scene, as POST /v1/scene returns it. */
@Serializable
data class SceneResult(
    val title: String = "",
    val titleJa: String = "",
    val situationEn: String = "",
    val placeEn: String = "",
    val partnerNameJa: String = "",
    val partnerNameEn: String = "",
    val partnerRole: String = "",
    val partnerGender: String = "",
    val track: String = "everyday",
    val beats: List<SceneResultBeat> = emptyList(),
    val closing: SceneLine = SceneLine(),
)

/** A scene kept on the phone: what was asked for and what the coach wrote. */
@Serializable
data class SavedScene(
    val id: String = "",
    /** "conversation" or "monologue" (a speech). */
    val kind: String = KIND_CONVERSATION,
    val description: String = "",
    /** Milliseconds since 1970. */
    @Serializable(with = TimeMillisSerializer::class)
    val createdAt: Long = 0L,
    @Serializable(with = TimeMillisSerializer::class)
    val updatedAt: Long = 0L,
    val result: SceneResult = SceneResult(),
) {
    /** Nobody else speaks. */
    val isMonologue: Boolean
        get() = kind == KIND_MONOLOGUE || result.beats.all { it.partner.japanese.isBlank() }

    val personaID: String get() = "$id.partner"

    /** The beats with a line for the learner to say; anything else can't be practised. */
    private val usableBeats: List<IndexedValue<SceneResultBeat>>
        get() = result.beats.withIndex().filter { it.value.learner.japanese.isNotBlank() }

    val lineCount: Int get() = usableBeats.size

    /** As an ordinary scene: the partner's lines are the beats' lines, the learner's line the one response. */
    fun toScenario(): Scenario = Scenario(
        id = id,
        title = result.title.ifBlank { "My scene" },
        titleJa = result.titleJa,
        track = if (result.track == "work") "work" else "everyday",
        level = 3,
        personaID = personaID,
        situationEn = result.situationEn,
        placeEn = result.placeEn.ifBlank { null },
        targetTerms = emptyList(),
        beats = usableBeats.map { (index, beat) ->
            ScenarioBeat(
                id = "b${index + 1}",
                line = beat.partner.japanese.trim(),
                kana = beat.partner.kana,
                english = beat.partner.english,
                intentEn = beat.hintEn.ifBlank { null },
                hintEn = beat.hintEn,
                responses = listOf(ModelLine(beat.learner.japanese.trim(), beat.learner.kana, beat.learner.english)),
            )
        },
        closingLine = result.closing.japanese.trim(),
        closingKana = result.closing.kana,
        closingEnglish = result.closing.english,
        field = null,
    )

    fun toPersona(): Persona = Persona(
        id = personaID,
        nameJa = result.partnerNameJa,
        nameEn = result.partnerNameEn,
        role = result.partnerRole,
        speakingRate = 1.0,
        voiceGender = result.partnerGender.lowercase().ifBlank { null },
    )

    /** Every line's words, by the line's Japanese ({name} kept), so the Words button works. */
    fun glossary(): Map<String, List<WordGloss>> {
        val lines = result.beats.flatMap { listOf(it.partner, it.learner) } + result.closing
        return lines.filter { it.japanese.isNotBlank() && it.words.isNotEmpty() }
            .associate { line ->
                line.japanese.trim() to line.words.filter { it.ja.isNotEmpty() }
                    .map { WordGloss(it.ja, it.kana.ifEmpty { it.ja }, it.en) }
            }
            .filterValues { it.isNotEmpty() }
    }

    companion object {
        const val KIND_CONVERSATION = "conversation"
        const val KIND_MONOLOGUE = "monologue"
    }
}

/** The course plus the learner's own scenes, which can then be read, heard and practised like any other. */
fun ContentLibrary.including(scenes: List<SavedScene>): ContentLibrary {
    if (scenes.isEmpty()) return this
    val ids = scenes.map { it.id }.toSet()
    val personaIDs = scenes.map { it.personaID }.toSet()
    return ContentLibrary(
        items = items,
        scenarios = scenarios.filter { it.id !in ids } + scenes.map { it.toScenario() },
        personas = personas.filter { it.id !in personaIDs } + scenes.map { it.toPersona() },
        vocabulary = vocabulary,
        cues = cues,
        // The course's own word lists win for a line both have.
        glossary = scenes.fold(emptyMap<String, List<WordGloss>>()) { all, scene -> all + scene.glossary() } + glossary,
    )
}

/** Reading and writing saved scenes, and bringing in scenes from a file. */
object MyScenes {
    val json = Json {
        ignoreUnknownKeys = true
        coerceInputValues = true
        // Lenient, so a time written as a number by another app still reads.
        isLenient = true
        // Empty lines (a speech's other side) are written out, as the shared format has them.
        encodeDefaults = true
        prettyPrint = true
    }

    private val listSerializer = ListSerializer(SavedScene.serializer())

    fun newID(): String = "my." + UUID.randomUUID().toString().replace("-", "").take(12)

    /** A file's scenes: one saved scene, or an array of them. Throws if it isn't either. */
    fun decode(text: String): List<SavedScene> = when (val element = json.parseToJsonElement(text)) {
        is JsonArray -> element.map { json.decodeFromJsonElement(SavedScene.serializer(), it) }
        is JsonObject -> listOf(json.decodeFromJsonElement(SavedScene.serializer(), element))
        else -> throw IllegalArgumentException("Not a scene")
    }

    fun encode(scenes: List<SavedScene>): String = json.encodeToString(listSerializer, scenes)

    fun encode(scene: SavedScene): String = json.encodeToString(SavedScene.serializer(), scene)

    /** The coach's scene as JSON, sent back as `previous` when changing it. */
    fun encode(result: SceneResult): String = json.encodeToString(SceneResult.serializer(), result)

    /**
     * Adds imported scenes to the saved ones: a scene with the same id replaces the old one. Scenes with nothing to
     * practise are skipped, and every id is kept apart from the course's ("my." in front). Returns the new list
     * (newest first) and how many came in.
     */
    fun merge(saved: List<SavedScene>, incoming: List<SavedScene>, now: Long): Pair<List<SavedScene>, Int> {
        val accepted = incoming.filter { it.lineCount > 0 }.map { scene ->
            val id = when {
                scene.id.isBlank() -> newID()
                scene.id.startsWith("my.") -> scene.id
                else -> "my." + scene.id
            }
            scene.copy(
                id = id,
                kind = if (scene.kind == SavedScene.KIND_MONOLOGUE) SavedScene.KIND_MONOLOGUE else SavedScene.KIND_CONVERSATION,
                createdAt = if (scene.createdAt > 0) scene.createdAt else now,
                updatedAt = if (scene.updatedAt > 0) scene.updatedAt else now,
            )
        }.distinctBy { it.id }
        val ids = accepted.map { it.id }.toSet()
        return (accepted + saved.filter { it.id !in ids }) to accepted.size
    }
}
