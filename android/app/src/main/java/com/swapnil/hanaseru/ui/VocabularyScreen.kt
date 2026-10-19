package com.swapnil.hanaseru.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.swapnil.hanaseru.content.ContentLibrary
import com.swapnil.hanaseru.voice.Speaker
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import java.text.Normalizer

/** Every word in the course, with where it's used; search in Japanese, romaji or English. */
@Composable
fun VocabularyScreen(library: ContentLibrary, speaker: Speaker, prefs: Prefs, onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var query by rememberSaveable { mutableStateOf("") }
    // The word being said: a new tap replaces it, and leaving the screen stops it (and nothing else).
    var saying by remember { mutableStateOf<Job?>(null) }
    DisposableEffect(Unit) {
        onDispose { saying?.cancel() }
    }
    val all = remember { library.vocabulary.sortedBy { it.kana } }
    val sources = remember {
        val map = mutableMapOf<String, MutableList<String>>()
        for (scenario in library.scenarios) {
            for (term in library.vocabulary(scenario)) map.getOrPut(term.id) { mutableListOf() }.add(scenario.title)
        }
        map
    }
    val wanted = plain(query.trim())
    val shown = if (wanted.isEmpty()) all else all.filter { term ->
        listOf(term.japanese, term.kana, term.letters, term.english).any { plain(it).contains(wanted, ignoreCase = true) }
    }

    Scaffold(topBar = {
        BackBar("My vocabulary", onBack) {
            IconButton(onClick = {
                val text = buildString {
                    appendLine("My Japanese vocabulary")
                    appendLine()
                    for (term in all) {
                        append(term.japanese)
                        if (term.kana != term.japanese) append(" (${term.kana})")
                        appendLine(" — ${term.letters} — ${term.english}")
                    }
                }
                shareText(context, "My Japanese vocabulary", text)
            }) {
                Icon(Icons.Filled.Share, contentDescription = "Share the word list")
            }
        }
    }) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
        ) {
            item(key = "search") {
                OutlinedTextField(
                    value = query,
                    onValueChange = { query = it },
                    placeholder = { Text("Japanese, romaji or English") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            item(key = "options") {
                Row(modifier = Modifier.padding(vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(selected = prefs.showRomaji, onClick = { prefs.showRomaji = !prefs.showRomaji },
                               label = { Text("Romaji") })
                    Text(
                        "${shown.size} words",
                        modifier = Modifier.padding(top = 14.dp),
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            items(shown, key = { it.id }) { term ->
                WordRow(term = term, detail = sources[term.id]?.joinToString(", ") ?: "", showRomaji = prefs.showRomaji) {
                    saying?.cancel()
                    saying = scope.launch { speaker.speak(term.japanese, Speaker.Voice.COACH_JAPANESE, 0.9f) }
                }
                HorizontalDivider()
            }
        }
    }
}

/** Latin letters without long-vowel marks, so "kyo" finds "kyō" (kana keep their marks). */
private fun plain(text: String): String =
    Normalizer.normalize(text, Normalizer.Form.NFD).replace(Regex("(?<=\\p{IsLatin})\\p{M}+"), "")
