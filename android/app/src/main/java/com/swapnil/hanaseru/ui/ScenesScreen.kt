package com.swapnil.hanaseru.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.swapnil.hanaseru.content.ContentLibrary

/** A group of scenes in the list. */
private data class SceneGroup(val title: String, val field: String?, val track: String)

/** Every conversation, grouped: your own field's scenes first, then everyday life, then the other field's. */
@Composable
fun ScenesScreen(library: ContentLibrary, prefs: Prefs, onBack: () -> Unit, onOpen: (String) -> Unit) {
    val railway = SceneGroup("Railway work", "engineering", "work")
    val finance = listOf(SceneGroup("Finance at work", "finance", "work"), SceneGroup("Money in Japan", "finance", "everyday"))
    val everyday = SceneGroup("Everyday", null, "everyday")
    val groups = if (prefs.workField == "finance") finance + everyday + railway else listOf(railway, everyday) + finance
    Scaffold(topBar = { BackBar("Scenes", onBack) }) { padding ->
        LazyColumn(modifier = Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(bottom = 24.dp)) {
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
                val scenes = library.scenarios.filter { it.track == group.track && it.workField == group.field }.sortedBy { it.level }
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
