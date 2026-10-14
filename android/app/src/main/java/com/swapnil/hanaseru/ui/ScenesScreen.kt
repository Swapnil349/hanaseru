package com.swapnil.hanaseru.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.swapnil.hanaseru.content.ContentLibrary

/** Every conversation, by track. */
@Composable
fun ScenesScreen(library: ContentLibrary, onBack: () -> Unit, onOpen: (String) -> Unit) {
    Scaffold(topBar = { BackBar("Scenes", onBack) }) { padding ->
        LazyColumn(modifier = Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(bottom = 24.dp)) {
            for ((track, title) in listOf("work" to "Work", "everyday" to "Everyday")) {
                val scenes = library.scenarios.filter { it.track == track }.sortedBy { it.level }
                if (scenes.isEmpty()) continue
                item(key = "header-$track") {
                    Text(
                        title.uppercase(),
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
