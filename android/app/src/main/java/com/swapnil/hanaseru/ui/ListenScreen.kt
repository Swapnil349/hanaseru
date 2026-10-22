package com.swapnil.hanaseru.ui

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.swapnil.hanaseru.content.ContentLibrary
import com.swapnil.hanaseru.content.Romaji
import com.swapnil.hanaseru.listen.ListenHistory
import com.swapnil.hanaseru.listen.ListenLanguage
import com.swapnil.hanaseru.listen.ListenLength
import com.swapnil.hanaseru.listen.ListenPlaylist
import com.swapnil.hanaseru.listen.ListenService
import com.swapnil.hanaseru.listen.ListenSession
import com.swapnil.hanaseru.listen.ListenSource
import com.swapnil.hanaseru.listen.ListenSpeed
import com.swapnil.hanaseru.listen.ListenState
import com.swapnil.hanaseru.voice.Speaker

/**
 * Listen: choose, press Play, put the phone away. While it plays the screen shows what is being said, but nothing
 * needs to be looked at; the headphones', car's and lock screen's buttons do the same as the big ones here.
 */
@Composable
fun ListenScreen(
    library: ContentLibrary,
    prefs: Prefs,
    speaker: Speaker,
    learnerName: String,
    myScenes: Set<String>,
    onBack: () -> Unit,
) {
    val context = LocalContext.current
    val state by ListenSession.state.collectAsState()
    var note by remember { mutableStateOf("") }

    val begin: () -> Unit = {
        // Anything the app itself was saying stops, so the two never talk over each other.
        speaker.stop()
        val options = prefs.listenOptions
        val playlist = ListenPlaylist.build(library, options, prefs.workField, myScenes, learnerName,
                                            ListenHistory(context).recent)
        if (playlist.scenes.isEmpty()) {
            note = "There are no scenes to play yet."
        } else {
            note = ""
            ListenService.start(context, playlist)
        }
    }
    // The notification carries the controls on the lock screen; Listen plays either way.
    val notifications = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { begin() }
    val play: () -> Unit = {
        val needsAsking = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        if (needsAsking) notifications.launch(Manifest.permission.POST_NOTIFICATIONS) else begin()
    }

    var japaneseVoice by remember { mutableStateOf(true) }
    LaunchedEffect(Unit) { japaneseVoice = speaker.hasJapanese() }

    Scaffold(topBar = { BackBar("Listen", onBack) }) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            if (!japaneseVoice) {
                Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondary.copy(alpha = 0.15f))) {
                    Text(
                        "This phone has no Japanese voice yet, so the scenes can't be heard. In Settings › System › " +
                            "Languages › Text-to-speech, choose Google's engine and install Japanese voice data.",
                        modifier = Modifier.padding(12.dp),
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
            }
            if (state.isActive) {
                NowPlaying(state, prefs)
            } else {
                Choices(prefs, hasMyScenes = myScenes.isNotEmpty())
                if (state.status == ListenState.Status.FINISHED) {
                    Text("お疲れさまでした · That's the end. Well done.", color = Palette.go, fontWeight = FontWeight.SemiBold)
                }
                if (note.isNotEmpty()) Text(note, color = MaterialTheme.colorScheme.primary)
                Button(onClick = play, modifier = Modifier.fillMaxWidth().height(72.dp)) {
                    Icon(Icons.Filled.PlayArrow, contentDescription = null, modifier = Modifier.size(32.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("Play", style = MaterialTheme.typography.titleLarge)
                }
                Text(
                    "Keeps playing with the screen off. Pause, or skip a scene, with your headphones, the car's buttons " +
                        "or the lock screen.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun Choices(prefs: Prefs, hasMyScenes: Boolean) {
    val options = prefs.listenOptions
    ChoiceRow("Language", listOf(ListenLanguage.JAPANESE to "Japanese only", ListenLanguage.JAPANESE_ENGLISH to "Japanese + English"),
              options.language) { prefs.listenOptions = options.copy(language = it) }
    ChoiceRow("Length", listOf(ListenLength.FIVE to "About 5 minutes", ListenLength.TEN to "About 10 minutes"),
              options.length) { prefs.listenOptions = options.copy(length = it) }
    ChoiceRow(
        "Scenes from",
        listOf(ListenSource.MY_WORK to "My work", ListenSource.EVERYDAY to "Everyday", ListenSource.MY_SCENES to "My scenes",
               ListenSource.EVERYTHING to "Everything"),
        options.source,
    ) { prefs.listenOptions = options.copy(source = it) }
    if (options.source == ListenSource.MY_SCENES && !hasMyScenes) {
        Text("You have no scenes of your own yet, so scenes from everything will play.",
             style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    ChoiceRow("Speed", listOf(ListenSpeed.NATURAL to "Natural", ListenSpeed.SLOWER to "Slower"), options.speed) {
        prefs.listenOptions = options.copy(speed = it)
    }
}

@Composable
private fun <T> ChoiceRow(title: String, choices: List<Pair<T, String>>, selected: T, onSelect: (T) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(title.uppercase(), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Row(modifier = Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            for ((value, label) in choices) {
                FilterChip(selected = value == selected, onClick = { onSelect(value) }, label = { Text(label) })
            }
        }
    }
}

/** What is playing, in big type, with big buttons: usable at a glance. */
@Composable
private fun NowPlaying(state: ListenState, prefs: Prefs) {
    val context = LocalContext.current
    val colors = MaterialTheme.colorScheme
    val paused = state.status == ListenState.Status.PAUSED
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        if (state.sceneNumber > 0) {
            Text("Scene ${state.sceneNumber} of ${state.sceneCount}", style = MaterialTheme.typography.labelLarge,
                 color = colors.primary)
        }
        Text(state.sceneTitle.ifBlank { "Listen" }, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
        if (state.sceneTitleJa.isNotBlank()) {
            Text(state.sceneTitleJa, style = MaterialTheme.typography.titleMedium, color = colors.onSurfaceVariant)
        }
    }
    state.line?.let { line ->
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(colors.surface, RoundedCornerShape(16.dp))
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            if (line.speaker.isNotBlank()) {
                Text(line.speaker, style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold,
                     color = colors.onSurfaceVariant)
            }
            Text(line.japanese, style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Medium)
            if (line.kana.isNotEmpty() && line.kana != line.japanese) {
                Text(line.kana, style = MaterialTheme.typography.titleMedium, color = colors.onSurfaceVariant)
            }
            if (prefs.showRomaji && line.kana.isNotEmpty()) {
                Text(Romaji.of(line.japanese, line.kana), style = MaterialTheme.typography.titleMedium,
                     fontStyle = FontStyle.Italic, color = colors.onSurfaceVariant)
            }
            if (prefs.showEnglish && line.english.isNotEmpty()) {
                Text(line.english, style = MaterialTheme.typography.titleMedium, color = colors.onSurfaceVariant)
            }
        }
    }
    if (paused) {
        Text(state.message.ifBlank { "Paused. Play carries on from this line." }, color = colors.onSurfaceVariant)
    }
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        BigStep(Icons.Filled.SkipPrevious, "Previous scene") { ListenService.send(context, ListenService.ACTION_PREVIOUS) }
        Button(
            onClick = { ListenService.send(context, ListenService.ACTION_TOGGLE) },
            modifier = Modifier.weight(1f).height(80.dp),
        ) {
            Icon(if (paused) Icons.Filled.PlayArrow else Icons.Filled.Pause, contentDescription = null, modifier = Modifier.size(36.dp))
            Spacer(Modifier.width(6.dp))
            Text(if (paused) "Play" else "Pause", style = MaterialTheme.typography.titleLarge)
        }
        BigStep(Icons.Filled.SkipNext, "Next scene") { ListenService.send(context, ListenService.ACTION_NEXT) }
    }
    OutlinedButton(onClick = { ListenService.send(context, ListenService.ACTION_STOP) }, modifier = Modifier.fillMaxWidth()) {
        Icon(Icons.Filled.Stop, contentDescription = null)
        Spacer(Modifier.width(6.dp))
        Text("Stop")
    }
    Row(modifier = Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        FilterChip(selected = prefs.showEnglish, onClick = { prefs.showEnglish = !prefs.showEnglish }, label = { Text("English") })
        FilterChip(selected = prefs.showRomaji, onClick = { prefs.showRomaji = !prefs.showRomaji }, label = { Text("Romaji") })
    }
}

@Composable
private fun BigStep(icon: ImageVector, label: String, onClick: () -> Unit) {
    FilledTonalButton(onClick = onClick, modifier = Modifier.height(80.dp)) {
        Icon(icon, contentDescription = label, modifier = Modifier.size(36.dp))
    }
}
