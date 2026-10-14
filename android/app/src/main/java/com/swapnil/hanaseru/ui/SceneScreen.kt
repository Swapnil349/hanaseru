package com.swapnil.hanaseru.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.swapnil.hanaseru.content.ContentLibrary
import com.swapnil.hanaseru.content.ScriptEntry
import com.swapnil.hanaseru.content.VocabularyTerm
import com.swapnil.hanaseru.content.script
import com.swapnil.hanaseru.content.scriptText
import com.swapnil.hanaseru.voice.Speaker
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * One scene: the situation, the whole conversation to read and hear (in Japanese, kana, romaji and English),
 * "Test me" to hide your own lines, and the words it uses.
 */
@Composable
fun SceneScreen(library: ContentLibrary, scenarioID: String, speaker: Speaker, prefs: Prefs, onBack: () -> Unit) {
    val scenario = library.scenario(scenarioID)
    if (scenario == null) {
        Text("This scene isn't in this version.", modifier = Modifier.padding(24.dp))
        return
    }
    val context = LocalContext.current
    val entries = remember(scenarioID) { library.script(scenario, learnerName = "") }
    val words = remember(scenarioID) { library.vocabulary(scenario) }
    val scope = rememberCoroutineScope()
    var playing by remember { mutableStateOf<String?>(null) }
    var job by remember { mutableStateOf<Job?>(null) }
    var testMe by remember { mutableStateOf(false) }
    var slowly by remember { mutableStateOf(false) }
    val revealed = remember { mutableStateListOf<String>() }

    // Plays lines one after another in their speakers' voices, like the conversation itself.
    fun play(lines: List<ScriptEntry>) {
        job?.cancel()
        speaker.stop()
        job = scope.launch {
            try {
                for (entry in lines) {
                    playing = entry.id
                    speaker.speak(entry.japanese, entry.voice, if (slowly) 0.7f else 0.95f)
                    delay(350)
                }
            } finally {
                playing = null
            }
        }
    }

    DisposableEffect(Unit) {
        onDispose {
            job?.cancel()
            speaker.stop()
        }
    }

    Scaffold(topBar = {
        BackBar(scenario.title, onBack) {
            IconButton(onClick = {
                shareText(context, scenario.title, scriptText(scenario.title, scenario.situationEn, entries))
            }) {
                Icon(Icons.Filled.Share, contentDescription = "Share the conversation")
            }
        }
    }) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            item(key = "situation") {
                Column {
                    Text(scenario.titleJa, style = MaterialTheme.typography.titleSmall,
                         color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(Modifier.height(4.dp))
                    Text(scenario.situationEn, style = MaterialTheme.typography.bodyLarge)
                }
            }
            item(key = "play") {
                val active = playing != null
                Button(onClick = {
                    if (active) {
                        job?.cancel()
                        speaker.stop()
                    } else {
                        play(entries)
                    }
                }, modifier = Modifier.fillMaxWidth()) {
                    Icon(if (active) Icons.Filled.Stop else Icons.Filled.PlayArrow, contentDescription = null)
                    Spacer(Modifier.width(8.dp))
                    Text(if (active) "Stop" else "Play the whole conversation")
                }
            }
            item(key = "options") {
                Row(
                    modifier = Modifier.horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    FilterChip(selected = prefs.showEnglish, onClick = { prefs.showEnglish = !prefs.showEnglish },
                               label = { Text("English") })
                    FilterChip(selected = prefs.showRomaji, onClick = { prefs.showRomaji = !prefs.showRomaji },
                               label = { Text("Romaji") })
                    FilterChip(selected = testMe, onClick = {
                        testMe = !testMe
                        revealed.clear()
                    }, label = { Text("Test me") })
                    FilterChip(selected = slowly, onClick = { slowly = !slowly }, label = { Text("Slowly") })
                }
            }
            items(entries, key = { it.id }) { entry ->
                ScriptRow(
                    entry = entry,
                    highlighted = playing == entry.id,
                    hidden = testMe && entry.isLearner && entry.id !in revealed,
                    showRomaji = prefs.showRomaji,
                    showEnglish = prefs.showEnglish,
                    onReveal = { revealed.add(entry.id) },
                    onPlay = { play(listOf(entry)) },
                )
            }
            if (words.isNotEmpty()) {
                item(key = "words-header") {
                    Text(
                        "Words in this conversation",
                        modifier = Modifier.padding(top = 16.dp),
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
                items(words, key = { "w-" + it.id }) { term ->
                    WordRow(term = term, detail = "", showRomaji = prefs.showRomaji) {
                        play(listOf(ScriptEntry("w-" + term.id, "", false, term.japanese, term.kana, term.letters,
                                                term.english, Speaker.Voice.COACH_JAPANESE)))
                    }
                    HorizontalDivider()
                }
            }
        }
    }
}

@Composable
private fun ScriptRow(
    entry: ScriptEntry,
    highlighted: Boolean,
    hidden: Boolean,
    showRomaji: Boolean,
    showEnglish: Boolean,
    onReveal: () -> Unit,
    onPlay: () -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = if (highlighted) colors.primary.copy(alpha = 0.14f) else colors.surface,
        ),
    ) {
        Row(modifier = Modifier.padding(14.dp), verticalAlignment = Alignment.Top) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    entry.speaker,
                    style = MaterialTheme.typography.labelLarge,
                    fontWeight = FontWeight.SemiBold,
                    color = if (entry.isLearner) colors.primary else colors.onSurfaceVariant,
                )
                Spacer(Modifier.height(4.dp))
                if (hidden) {
                    // Test me: the meaning is the cue; the Japanese stays hidden until tapped.
                    Text(entry.english, style = MaterialTheme.typography.bodyLarge)
                    TextButton(onClick = onReveal) { Text("Tap to see the Japanese") }
                } else {
                    JapaneseBlock(entry.japanese, entry.kana, entry.romaji, entry.english, showRomaji, showEnglish)
                }
            }
            IconButton(onClick = onPlay) {
                Icon(Icons.AutoMirrored.Filled.VolumeUp, contentDescription = "Hear this line", tint = colors.primary)
            }
        }
    }
}

/** A word with its reading and meaning; tap to hear it. */
@Composable
fun WordRow(term: VocabularyTerm, detail: String, showRomaji: Boolean, onPlay: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onPlay)
            .padding(vertical = 10.dp, horizontal = 4.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(term.japanese, style = MaterialTheme.typography.titleMedium)
            if (term.kana != term.japanese) {
                Text(term.kana, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (showRomaji) {
                Text(term.letters, style = MaterialTheme.typography.bodySmall, fontStyle = FontStyle.Italic,
                     color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        Column(modifier = Modifier.weight(1f), horizontalAlignment = Alignment.End) {
            Text(term.english, style = MaterialTheme.typography.bodyMedium, textAlign = TextAlign.End)
            if (detail.isNotEmpty()) {
                Text(detail, style = MaterialTheme.typography.labelSmall, textAlign = TextAlign.End,
                     color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}
