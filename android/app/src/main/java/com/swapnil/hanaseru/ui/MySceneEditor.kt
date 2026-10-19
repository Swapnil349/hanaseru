package com.swapnil.hanaseru.ui

import android.Manifest
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import com.swapnil.hanaseru.coach.CoachClient
import com.swapnil.hanaseru.coach.CoachSettings
import com.swapnil.hanaseru.coach.MyScenesStore
import com.swapnil.hanaseru.content.MyScenes
import com.swapnil.hanaseru.content.SavedScene
import com.swapnil.hanaseru.voice.Listener
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import kotlin.math.roundToInt

/** How polite the lines are: the coach's three choices. */
private val politenessChoices = listOf("casual" to "Casual", "professional" to "Professional", "veryPolite" to "Very polite")

/**
 * A new scene written by the AI coach from your description (spoken in English or typed), or a change to one of
 * yours. Writing takes a minute or two, so what's happening is shown all the while.
 */
@Composable
fun MySceneEditor(
    /** The scene to change, or null for a new one. */
    existing: SavedScene?,
    coach: CoachClient,
    settings: CoachSettings,
    store: MyScenesStore,
    listener: Listener,
    onBack: () -> Unit,
    onSettings: () -> Unit,
    onSaved: (String) -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var kind by rememberSaveable { mutableStateOf(existing?.kind ?: SavedScene.KIND_CONVERSATION) }
    var description by rememberSaveable { mutableStateOf("") }
    var length by rememberSaveable { mutableStateOf((existing?.lineCount ?: 6).coerceIn(2, 12)) }
    var politeness by rememberSaveable { mutableStateOf("professional") }
    var error by remember { mutableStateOf("") }
    var writing by remember { mutableStateOf(false) }
    var seconds by remember { mutableIntStateOf(0) }
    // Speaking the description: what's heard so far, and the listening itself.
    var dictating by remember { mutableStateOf(false) }
    var heard by remember { mutableStateOf("") }
    var listening by remember { mutableStateOf<Job?>(null) }

    fun dictate() {
        listening?.cancel()
        heard = ""
        dictating = true
        listening = scope.launch {
            try {
                // Your English, in an Indian English accent first (it understands American English too).
                val text = listener.listen(silenceMillis = 2_500, language = "en-IN", maxMillis = 60_000) { heard = it }
                if (text.isNotBlank()) description = listOf(description.trim(), text.trim()).filter { it.isNotEmpty() }.joinToString(" ")
            } finally {
                dictating = false
                heard = ""
            }
        }
    }

    val microphone = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) {
            dictate()
        } else {
            error = "To speak your description, allow the microphone. You can type it instead."
        }
    }

    DisposableEffect(Unit) {
        onDispose { listening?.cancel() }
    }

    // Seconds since asking, for the progress text.
    LaunchedEffect(writing) {
        seconds = 0
        while (writing) {
            delay(1_000)
            seconds++
        }
    }

    fun write() {
        val scene = existing
        listening?.cancel()
        error = ""
        writing = true
        scope.launch {
            try {
                val result = coach.scene(
                    description = description,
                    kind = kind,
                    politeness = politeness,
                    length = length,
                    learnerName = settings.learnerName,
                    previous = scene?.result,
                )
                val now = MyScenesStore.now()
                // A change is noted under the first description, as the iPhone app does.
                val asked = description.trim()
                val saved = if (scene != null) {
                    scene.copy(result = result, updatedAt = now,
                               description = if (scene.description.isEmpty()) "Changed: $asked"
                                             else scene.description + "\nChanged: " + asked)
                } else {
                    SavedScene(id = MyScenes.newID(), kind = kind, description = asked,
                               createdAt = now, updatedAt = now, result = result)
                }
                store.save(saved)
                writing = false
                onSaved(saved.id)
            } catch (failure: CoachClient.Failure) {
                error = failure.message ?: "The coach couldn't write the scene. Try again."
                writing = false
            } catch (failed: IOException) {
                error = "The scene was written but couldn't be saved on this phone. Is its storage full?"
                writing = false
            }
        }
    }

    val title = if (existing == null) "New scene" else "Change this scene"
    Scaffold(topBar = { BackBar(title, onBack) }) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            if (!settings.isSetUp) {
                Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondary.copy(alpha = 0.15f))) {
                    Column(modifier = Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("The AI coach writes your scenes. Add its passphrase in Settings first.",
                             style = MaterialTheme.typography.bodyMedium)
                        OutlinedButton(onClick = onSettings) { Text("Open Settings") }
                    }
                }
            }

            if (existing == null) {
                Text("What kind?", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(selected = kind == SavedScene.KIND_CONVERSATION, enabled = !writing,
                               onClick = { kind = SavedScene.KIND_CONVERSATION }, label = { Text("Conversation") })
                    FilterChip(selected = kind == SavedScene.KIND_MONOLOGUE, enabled = !writing,
                               onClick = { kind = SavedScene.KIND_MONOLOGUE }, label = { Text("Speech") })
                }
                Text(
                    if (kind == SavedScene.KIND_MONOLOGUE) "Just you speaking: a self-introduction, a presentation, a toast."
                    else "You and one other person, taking turns.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            } else {
                Text(existing.result.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            }

            Text(
                if (existing == null) "Describe it in English" else "What should change?",
                style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold,
            )
            OutlinedTextField(
                value = description,
                onValueChange = { description = it },
                enabled = !writing,
                placeholder = {
                    Text(
                        if (existing != null) "e.g. Make it more casual, and ask about lunch at the end"
                        else if (kind == SavedScene.KIND_MONOLOGUE) "e.g. Introducing myself to my new team at the bank"
                        else "e.g. Asking a station attendant which platform the Kodama leaves from"
                    )
                },
                modifier = Modifier.fillMaxWidth().heightIn(min = 120.dp),
            )
            OutlinedButton(
                enabled = !writing && listener.isAvailable,
                onClick = {
                    if (dictating) {
                        // Ends the turn but keeps what was heard.
                        listener.cancel()
                    } else {
                        val granted = ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
                            PackageManager.PERMISSION_GRANTED
                        if (granted) dictate() else microphone.launch(Manifest.permission.RECORD_AUDIO)
                    }
                },
            ) {
                Icon(if (dictating) Icons.Filled.Stop else Icons.Filled.Mic, contentDescription = null)
                Spacer(Modifier.width(4.dp))
                Text(if (dictating) "Stop" else "Speak in English")
            }
            if (dictating) {
                Text(heard.ifEmpty { "Listening… describe it in your own words." },
                     style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.primary)
            }
            if (!listener.isAvailable) {
                Text("Speech recognition isn't available on this phone; type the description instead.",
                     style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }

            Text(
                (if (kind == SavedScene.KIND_MONOLOGUE) "Sentences: " else "Your lines: ") + length,
                style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold,
            )
            Slider(
                value = length.toFloat(),
                onValueChange = { length = it.roundToInt().coerceIn(2, 12) },
                valueRange = 2f..12f,
                steps = 9,
                enabled = !writing,
            )

            Text("How polite", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Row(
                modifier = Modifier.horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                for ((value, label) in politenessChoices) {
                    FilterChip(selected = politeness == value, enabled = !writing, onClick = { politeness = value },
                               label = { Text(label) })
                }
            }

            Button(
                onClick = { write() },
                enabled = !writing && description.isNotBlank() && settings.isSetUp,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(if (existing == null) "Write my scene" else "Change my scene")
            }
            if (writing) {
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                Text(progressText(seconds), style = MaterialTheme.typography.bodyMedium)
                Text("You can keep this screen open; leaving it stops the request.",
                     style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (error.isNotEmpty()) {
                Text(error, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.error)
            }
        }
    }
}

/** What's happening while the coach writes, by how long it's been. */
private fun progressText(seconds: Int): String = when {
    seconds < 8 -> "Sending your description to the coach…"
    seconds < 45 -> "The coach is writing your scene… ($seconds s)"
    seconds < 100 -> "Still writing. The free server may have been asleep and is waking up. ($seconds s)"
    else -> "Nearly there: this can take up to three minutes. ($seconds s)"
}

/** Shares scenes as a .json file (the shared format): save it to Files or Drive, or send it to another device. */
fun shareScenes(context: Context, scenes: List<SavedScene>, title: String) {
    val text = if (scenes.size == 1) MyScenes.encode(scenes[0]) else MyScenes.encode(scenes)
    val folder = File(context.cacheDir, "shared").apply { mkdirs() }
    val name = title.replace(Regex("[^A-Za-z0-9 _-]"), "").trim().replace(' ', '-').ifEmpty { "my-scenes" }.take(60)
    val file = File(folder, "$name.json")
    file.writeText(text)
    val uri: Uri = FileProvider.getUriForFile(context, context.packageName + ".files", file)
    val send = Intent(Intent.ACTION_SEND).apply {
        type = "application/json"
        putExtra(Intent.EXTRA_STREAM, uri)
        putExtra(Intent.EXTRA_SUBJECT, title)
        clipData = ClipData.newRawUri(title, uri)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    context.startActivity(Intent.createChooser(send, title))
}

/** Reads scenes from a file you picked: one scene or an array. Null when it isn't a scene file. */
suspend fun readScenes(context: Context, uri: Uri): List<SavedScene>? = withContext(Dispatchers.IO) {
    runCatching {
        val text = context.contentResolver.openInputStream(uri)?.use { stream ->
            stream.bufferedReader(Charsets.UTF_8).readText()
        } ?: return@runCatching null
        if (text.length > 4_000_000) null else MyScenes.decode(text)
    }.getOrNull()
}
