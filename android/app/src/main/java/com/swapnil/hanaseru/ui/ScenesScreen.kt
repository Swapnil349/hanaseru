package com.swapnil.hanaseru.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.swapnil.hanaseru.coach.MyScenesStore
import com.swapnil.hanaseru.content.ContentLibrary
import kotlinx.coroutines.launch

/** A group of scenes in the list. */
private data class SceneGroup(val title: String, val field: String?, val track: String)

/** Your own scenes first, then every conversation, grouped: your field's scenes, everyday life, the other field's. */
@Composable
fun ScenesScreen(
    library: ContentLibrary,
    prefs: Prefs,
    myScenes: MyScenesStore,
    onBack: () -> Unit,
    onOpen: (String) -> Unit,
    onNewScene: () -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var message by remember { mutableStateOf("") }
    val mine = myScenes.scenes
    val mineIDs = mine.map { it.id }.toSet()
    val importer = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) {
            scope.launch {
                val scenes = readScenes(context, uri)
                message = when {
                    scenes == null -> "That file isn't a Hanaseru scene."
                    else -> when (val count = myScenes.import(scenes)) {
                        0 -> "No scenes to practise in that file."
                        1 -> "Imported 1 scene."
                        else -> "Imported $count scenes."
                    }
                }
            }
        }
    }

    val railway = SceneGroup("Railway work", "engineering", "work")
    val finance = listOf(SceneGroup("Finance at work", "finance", "work"), SceneGroup("Money in Japan", "finance", "everyday"))
    val everyday = SceneGroup("Everyday", null, "everyday")
    val groups = if (prefs.workField == "finance") finance + everyday + railway else listOf(railway, everyday) + finance
    Scaffold(topBar = { BackBar("Scenes", onBack) }) { padding ->
        LazyColumn(modifier = Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(bottom = 24.dp)) {
            item(key = "mine-header") {
                Column(
                    modifier = Modifier.padding(start = 20.dp, top = 16.dp, end = 20.dp, bottom = 6.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text("MY SCENES", style = MaterialTheme.typography.labelMedium,
                         color = MaterialTheme.colorScheme.onSurfaceVariant)
                    if (mine.isEmpty()) {
                        Text("Describe a conversation or a speech you need, and the AI coach writes it for you to practise.",
                             style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Row(
                        modifier = Modifier.horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Button(onClick = onNewScene) {
                            Icon(Icons.Filled.Add, contentDescription = null)
                            Spacer(Modifier.width(4.dp))
                            Text("New scene")
                        }
                        OutlinedButton(onClick = {
                            message = ""
                            // Any file: phones label .json files in different ways.
                            importer.launch(arrayOf("*/*"))
                        }) { Text("Import") }
                        if (mine.isNotEmpty()) {
                            OutlinedButton(onClick = { shareScenes(context, mine, "My Hanaseru scenes") }) { Text("Export all") }
                        }
                    }
                    if (message.isNotEmpty()) {
                        Text(message, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.primary)
                    }
                }
            }
            items(mine, key = { "mine-" + it.id }) { scene ->
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { onOpen(scene.id) }
                        .padding(horizontal = 20.dp, vertical = 12.dp)
                ) {
                    Text(scene.result.title.ifBlank { "My scene" }, style = MaterialTheme.typography.titleMedium,
                         fontWeight = FontWeight.Medium)
                    val what = if (scene.isMonologue) "Speech · ${scene.lineCount} sentences"
                               else "Conversation · ${scene.lineCount} lines"
                    Text(
                        listOf(scene.result.titleJa, what).filter { it.isNotEmpty() }.joinToString(" · "),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                HorizontalDivider(modifier = Modifier.padding(start = 20.dp))
            }
            item(key = "field") {
                Row(
                    modifier = Modifier.padding(start = 20.dp, top = 12.dp, end = 20.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text("My work:", modifier = Modifier.padding(top = 14.dp), style = MaterialTheme.typography.bodyMedium)
                    for ((value, label) in listOf("engineering" to "Railway", "finance" to "Finance")) {
                        FilterChip(selected = prefs.workField == value, onClick = { prefs.workField = value },
                                   label = { Text(label) })
                    }
                }
            }
            for (group in groups) {
                val scenes = library.scenarios
                    .filter { it.id !in mineIDs && it.track == group.track && it.workField == group.field }
                    .sortedBy { it.level }
                if (scenes.isEmpty()) continue
                item(key = "header-${group.title}") {
                    Text(
                        group.title.uppercase(),
                        modifier = Modifier.padding(start = 20.dp, top = 20.dp, bottom = 6.dp),
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                items(scenes, key = { it.id }) { scenario ->
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { onOpen(scenario.id) }
                            .padding(horizontal = 20.dp, vertical = 12.dp)
                    ) {
                        Text(scenario.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Medium)
                        Text(
                            "${scenario.titleJa} · ${scenario.beats.size} lines",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    HorizontalDivider(modifier = Modifier.padding(start = 20.dp))
                }
            }
        }
    }
}
