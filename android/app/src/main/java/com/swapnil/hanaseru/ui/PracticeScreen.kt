package com.swapnil.hanaseru.ui

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Replay
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material3.Button
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.swapnil.hanaseru.content.ContentLibrary
import com.swapnil.hanaseru.content.Romaji
import com.swapnil.hanaseru.practice.Progress
import com.swapnil.hanaseru.practice.ScenePractice
import com.swapnil.hanaseru.voice.Listener
import com.swapnil.hanaseru.voice.Speaker

/** A scene practised hands-free: the two sides, what to say, and controls that keep your place. */
@Composable
fun PracticeScreen(
    library: ContentLibrary,
    scenarioID: String,
    mode: ScenePractice.Mode,
    playAsPartner: Boolean,
    speaker: Speaker,
    listener: Listener,
    progress: Progress,
    prefs: Prefs,
    onBack: () -> Unit,
) {
    val scenario = library.scenario(scenarioID)
    if (scenario == null) {
        Text("This scene isn't in this version.", modifier = Modifier.padding(24.dp))
        return
    }
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val practice = remember(scenarioID, mode, playAsPartner) {
        ScenePractice(library, scenario, speaker, listener, progress, mode, playAsPartner, learnerName = "", scope = scope)
    }
    val state by practice.state.collectAsState()
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { practice.start() }

    LaunchedEffect(practice) {
        val granted = ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        if (granted) practice.start() else permission.launch(Manifest.permission.RECORD_AUDIO)
    }
    // The screen stays on while you practise.
    val view = LocalView.current
    DisposableEffect(practice) {
        view.keepScreenOn = true
        onDispose {
            view.keepScreenOn = false
            practice.stop()
        }
    }

    val other = if (playAsPartner) "Your usual part" else (practice.persona?.nameEn ?: "Colleague")
    val you = if (playAsPartner) "${practice.persona?.nameEn ?: "Colleague"} · you" else "You"

    Scaffold(topBar = { BackBar(scenario.title, onBack) }) { padding ->
        Column(modifier = Modifier.fillMaxSize().padding(padding)) {
            Column(
                modifier = Modifier
                    .weight(1f)
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(state.step, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)

                // The other side.
                if (state.otherJapanese.isNotEmpty()) {
                    SpeakerCard(
                        name = other,
                        active = state.speaking == ScenePractice.Who.OTHER,
                        onHear = { practice.hear(state.otherJapanese, yours = false) },
                        words = {
                            WordsButton(library, listOf(WordsLine(other, state.otherJapanese, state.otherEnglish)),
                                        onSay = { practice.hear(it, yours = true) }, onOpen = { practice.pause() })
                        },
                    ) {
                        JapaneseBlock(state.otherJapanese, state.otherKana, Romaji.of(state.otherJapanese, state.otherKana),
                                      state.otherEnglish, prefs.showRomaji, prefs.showEnglish)
                    }
                }

                // Your line: the Japanese while you're learning it, otherwise just what to say.
                state.line?.let { line ->
                    SpeakerCard(
                        name = you,
                        active = state.speaking == ScenePractice.Who.YOU,
                        onHear = { practice.hear(line.japanese, yours = true) },
                        onHearSlowly = { practice.hear(line.japanese, yours = true, slowly = true) },
                        words = {
                            if (state.answerShown) {
                                WordsButton(library, listOf(WordsLine("Your line", line.japanese, line.english)),
                                            onSay = { practice.hear(it, yours = true) }, onOpen = { practice.pause() })
                            }
                        },
                    ) {
                        Text(line.cueEn, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                        if (state.answerShown) {
                            JapaneseBlock(line.japanese, line.kana, line.romaji, "", prefs.showRomaji, false, large = true)
                        } else {
                            Text("Your turn — the Japanese shows after you answer", style = MaterialTheme.typography.bodySmall,
                                 color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }

                StatusLine(state.activity, state.heard, state.feedback)
            }

            // Controls.
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(MaterialTheme.colorScheme.surface)
                    .padding(horizontal = 16.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Scrubber(practice, state.position)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    StepButton(Icons.Filled.SkipPrevious, "Back") { practice.previous() }
                    StepButton(Icons.Filled.Replay, "Again") { practice.again() }
                    val paused = state.activity == ScenePractice.Activity.PAUSED
                    val finished = state.activity == ScenePractice.Activity.FINISHED
                    Button(
                        onClick = { if (finished) onBack() else practice.togglePause() },
                        modifier = Modifier.weight(1f).height(56.dp),
                    ) {
                        Icon(if (paused) Icons.Filled.PlayArrow else Icons.Filled.Pause, contentDescription = null)
                        Spacer(Modifier.width(6.dp))
                        Text(if (finished) "Done" else if (paused) "Play" else "Pause")
                    }
                    StepButton(Icons.Filled.SkipNext, "Next") { practice.next() }
                }
                Row(
                    modifier = Modifier.horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    FilterChip(selected = prefs.showEnglish, onClick = { prefs.showEnglish = !prefs.showEnglish },
                               label = { Text("English") })
                    FilterChip(selected = prefs.showRomaji, onClick = { prefs.showRomaji = !prefs.showRomaji },
                               label = { Text("Romaji") })
                }
            }
        }
    }
}

@Composable
private fun SpeakerCard(
    name: String,
    active: Boolean,
    onHear: () -> Unit,
    onHearSlowly: (() -> Unit)? = null,
    words: @Composable () -> Unit = {},
    content: @Composable () -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .border(if (active) 2.dp else 1.dp, if (active) colors.primary else colors.surfaceVariant, RoundedCornerShape(16.dp))
            .background(colors.surface, RoundedCornerShape(16.dp))
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                modifier = Modifier
                    .size(10.dp)
                    .background(if (active) colors.secondary else colors.surfaceVariant, CircleShape)
            )
            Spacer(Modifier.width(8.dp))
            Text(name, style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold,
                 color = colors.onSurfaceVariant, modifier = Modifier.weight(1f))
        }
        content()
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = onHear) {
                Icon(Icons.AutoMirrored.Filled.VolumeUp, contentDescription = null)
                Spacer(Modifier.width(4.dp))
                Text("Hear")
            }
            if (onHearSlowly != null) {
                OutlinedButton(onClick = onHearSlowly) { Text("Slowly") }
            }
            words()
        }
    }
}

@Composable
private fun StatusLine(activity: ScenePractice.Activity, heard: String, feedback: String) {
    val colors = MaterialTheme.colorScheme
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            when (activity) {
                ScenePractice.Activity.LISTENING -> {
                    Icon(Icons.Filled.Mic, contentDescription = null, tint = colors.secondary)
                    Spacer(Modifier.width(6.dp))
                    Text("あなたの番です · Your turn", color = colors.secondary, fontWeight = FontWeight.SemiBold)
                }
                ScenePractice.Activity.SPEAKING ->
                    Text("聞いてください · Listen", color = colors.primary, fontWeight = FontWeight.SemiBold)
                ScenePractice.Activity.PAUSED ->
                    Text("Paused. Tap Hear to listen to a line as often as you like.", color = colors.onSurfaceVariant)
                ScenePractice.Activity.FINISHED ->
                    Text("お疲れさまでした · Well done", color = Color(0xFF2B7A4B), fontWeight = FontWeight.SemiBold)
            }
        }
        if (heard.isNotEmpty()) Text("Heard: $heard", style = MaterialTheme.typography.bodyMedium)
        if (feedback.isNotEmpty()) Text(feedback, style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant)
        Text("Your voice is turned into text on this phone and never recorded.",
             style = MaterialTheme.typography.labelSmall, color = colors.onSurfaceVariant)
    }
}

/** Drag to any line of any step, at its question or straight at its answer. */
@Composable
private fun Scrubber(practice: ScenePractice, position: Int) {
    var dragging by remember { mutableStateOf<Float?>(null) }
    val stops = practice.stops
    if (stops.size < 2) return
    val shown = (dragging?.let { Math.round(it) } ?: position).coerceIn(0, stops.size - 1)
    Column {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(stops[shown].title, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary,
                 modifier = Modifier.weight(1f))
            if (dragging == null && !stops[shown].isAnswer && stops[shown].line != null) {
                Text(
                    "Go to the answer",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.clickable { practice.seek(shown + 1) }.padding(4.dp),
                )
            }
        }
        Slider(
            value = dragging ?: position.toFloat(),
            onValueChange = { dragging = it },
            onValueChangeFinished = {
                dragging?.let { practice.seek(Math.round(it)) }
                dragging = null
            },
            valueRange = 0f..(stops.size - 1).toFloat(),
            steps = maxOf(0, stops.size - 2),
        )
    }
}

@Composable
private fun StepButton(icon: ImageVector, label: String, onClick: () -> Unit) {
    FilledTonalButton(onClick = onClick, modifier = Modifier.height(56.dp)) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(icon, contentDescription = label)
            Text(label, style = MaterialTheme.typography.labelSmall)
        }
    }
}
