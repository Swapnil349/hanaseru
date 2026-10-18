package com.swapnil.hanaseru.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.MenuBook
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.swapnil.hanaseru.content.ContentLibrary
import com.swapnil.hanaseru.content.WordGloss

/** A line whose words can be looked at one by one. */
data class WordsLine(val title: String, val japanese: String, val english: String)

/** "Words": opens the meaning of every word in the lines. Hidden when none of them has a word list. */
@Composable
fun WordsButton(library: ContentLibrary, lines: List<WordsLine>, onSay: (String) -> Unit, onOpen: () -> Unit = {}) {
    val available = lines.filter { it.japanese.isNotEmpty() && library.words(it.japanese).isNotEmpty() }
    if (available.isEmpty()) return
    var showing by remember { mutableStateOf(false) }
    OutlinedButton(onClick = { onOpen(); showing = true }) {
        Icon(Icons.AutoMirrored.Filled.MenuBook, contentDescription = null)
        Spacer(Modifier.width(4.dp))
        Text("Words")
    }
    if (showing) {
        AlertDialog(
            onDismissRequest = { showing = false },
            confirmButton = { TextButton(onClick = { showing = false }) { Text("Done") } },
            title = { Text("Words") },
            text = {
                LazyColumn(modifier = Modifier.heightIn(max = 520.dp)) {
                    for (line in available) {
                        item {
                            Column(modifier = Modifier.padding(top = 8.dp, bottom = 6.dp)) {
                                Text(line.title.uppercase(), style = MaterialTheme.typography.labelMedium,
                                     color = MaterialTheme.colorScheme.onSurfaceVariant)
                                Text(line.japanese, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Medium)
                                if (line.english.isNotEmpty()) {
                                    Text(line.english, style = MaterialTheme.typography.bodyMedium,
                                         color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                            }
                        }
                        val words = library.words(line.japanese)
                        items(words.size) { index -> WordGlossRow(words[index]) { onSay(words[index].ja) } }
                    }
                }
            },
        )
    }
}

/** One word: the Japanese, its reading, and its meaning here. Tap to hear it. */
@Composable
private fun WordGlossRow(word: WordGloss, onSay: () -> Unit) {
    Column(modifier = Modifier.fillMaxWidth().clickable(onClick = onSay)) {
        Row(modifier = Modifier.padding(vertical = 8.dp), verticalAlignment = Alignment.Top) {
            Column(modifier = Modifier.weight(1f)) {
                Text(word.ja, style = MaterialTheme.typography.titleMedium)
                Text(if (word.kana == word.ja) word.romaji else "${word.kana} · ${word.romaji}",
                     style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Spacer(Modifier.width(12.dp))
            Text(word.en, modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium, textAlign = TextAlign.End)
        }
        HorizontalDivider()
    }
}
