package com.swapnil.hanaseru.ui

import androidx.compose.foundation.background
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
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.MenuBook
import androidx.compose.material.icons.filled.Forum
import androidx.compose.material.icons.filled.RecordVoiceOver
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.swapnil.hanaseru.content.ContentLibrary
import com.swapnil.hanaseru.voice.Speaker
import java.util.Calendar

@Composable
fun HanaseruApp(library: ContentLibrary, speaker: Speaker, prefs: Prefs) {
    val navigation = rememberNavController()
    NavHost(navController = navigation, startDestination = "home") {
        composable("home") {
            HomeScreen(
                speaker = speaker,
                sceneCount = library.scenarios.size,
                wordCount = library.vocabulary.size,
                onScenes = { navigation.navigate("scenes") },
                onVocabulary = { navigation.navigate("vocabulary") },
            )
        }
        composable("scenes") {
            ScenesScreen(library = library, onBack = { navigation.popBackStack() },
                         onOpen = { id -> navigation.navigate("scene/$id") })
        }
        composable("scene/{id}") { entry ->
            val id = entry.arguments?.getString("id") ?: ""
            SceneScreen(library = library, scenarioID = id, speaker = speaker, prefs = prefs,
                        onBack = { navigation.popBackStack() })
        }
        composable("vocabulary") {
            VocabularyScreen(library = library, speaker = speaker, prefs = prefs, onBack = { navigation.popBackStack() })
        }
    }
}

@Composable
private fun HomeScreen(
    speaker: Speaker,
    sceneCount: Int,
    wordCount: Int,
    onScenes: () -> Unit,
    onVocabulary: () -> Unit,
) {
    var japaneseVoice by remember { mutableStateOf(true) }
    LaunchedEffect(Unit) { japaneseVoice = speaker.hasJapanese() }
    val hour = Calendar.getInstance().get(Calendar.HOUR_OF_DAY)
    val (ja, en) = when (hour) {
        in 4..10 -> "おはようございます" to "Good morning"
        in 11..17 -> "こんにちは" to "Good afternoon"
        else -> "こんばんは" to "Good evening"
    }
    Scaffold { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Spacer(Modifier.height(8.dp))
            Box(
                Modifier
                    .width(36.dp)
                    .height(3.dp)
                    .background(MaterialTheme.colorScheme.primary)
            )
            Text(ja, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(en, style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.SemiBold)
            if (!japaneseVoice) {
                Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondary.copy(alpha = 0.15f))) {
                    Text(
                        "This phone has no Japanese voice yet. In Settings › System › Languages › Text-to-speech, " +
                            "choose Google's engine and install Japanese voice data.",
                        modifier = Modifier.padding(14.dp),
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
            }
            HomeCard(Icons.Filled.Forum, "Scenes", "$sceneCount conversations: read, hear and learn every line", onScenes)
            HomeCard(Icons.AutoMirrored.Filled.MenuBook, "My vocabulary", "All $wordCount words in the course, with romaji", onVocabulary)
            HomeCard(Icons.Filled.RecordVoiceOver, "Hands-free practice",
                     "Speaking practice with the coach — coming in the next Android update", null)
        }
    }
}

@Composable
private fun HomeCard(icon: ImageVector, title: String, detail: String, onClick: (() -> Unit)?) {
    val content: @Composable () -> Unit = {
        Row(modifier = Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(32.dp))
            Spacer(Modifier.width(14.dp))
            Column {
                Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
    if (onClick != null) {
        Card(onClick = onClick, modifier = Modifier.fillMaxWidth()) { content() }
    } else {
        Card(modifier = Modifier.fillMaxWidth()) { content() }
    }
}
