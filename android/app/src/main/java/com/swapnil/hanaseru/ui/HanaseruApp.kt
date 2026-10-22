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
import androidx.compose.material.icons.filled.Headphones
import androidx.compose.material.icons.filled.RecordVoiceOver
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
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
import com.swapnil.hanaseru.coach.CoachClient
import com.swapnil.hanaseru.coach.CoachSettings
import com.swapnil.hanaseru.coach.MyScenesStore
import com.swapnil.hanaseru.content.ContentLibrary
import com.swapnil.hanaseru.content.including
import com.swapnil.hanaseru.listen.ListenSession
import com.swapnil.hanaseru.practice.Progress
import com.swapnil.hanaseru.practice.ScenePractice
import com.swapnil.hanaseru.voice.Listener
import com.swapnil.hanaseru.voice.Speaker
import java.util.Calendar

@Composable
fun HanaseruApp(
    library: ContentLibrary,
    speaker: Speaker,
    listener: Listener,
    progress: Progress,
    prefs: Prefs,
    coachSettings: CoachSettings,
    coach: CoachClient,
    myScenes: MyScenesStore,
) {
    val navigation = rememberNavController()
    // The course plus your own scenes, rebuilt whenever they change. Screens read `.value` so they always see the
    // latest (the navigation graph keeps its first lambdas, so it mustn't capture a library itself).
    val current = remember(library) { derivedStateOf { library.including(myScenes.scenes) } }
    NavHost(navController = navigation, startDestination = "home") {
        composable("home") {
            HomeScreen(
                speaker = speaker,
                sceneCount = current.value.scenarios.size,
                wordCount = current.value.vocabulary.size,
                onScenes = { navigation.navigate("scenes") },
                onListen = { navigation.navigate("listen") },
                onVocabulary = { navigation.navigate("vocabulary") },
                onSettings = { navigation.navigate("settings") },
            )
        }
        composable("scenes") {
            ScenesScreen(library = current.value, prefs = prefs, myScenes = myScenes, onBack = { navigation.popBackStack() },
                         onOpen = { id -> navigation.navigate("scene/$id") },
                         onNewScene = { navigation.navigate("myscene/new") })
        }
        composable("scene/{id}") { entry ->
            val id = entry.arguments?.getString("id") ?: ""
            SceneScreen(library = current.value, scenarioID = id, speaker = speaker, listener = listener, prefs = prefs,
                        learnerName = coachSettings.learnerName, myScene = myScenes.scene(id),
                        onBack = { navigation.popBackStack() },
                        onPractise = { mode, asPartner -> navigation.navigate("practice/$id/${mode.name}/$asPartner") },
                        onChange = { navigation.navigate("myscene/change/$id") },
                        onDelete = {
                            navigation.popBackStack()
                            myScenes.delete(id)
                        })
        }
        composable("practice/{id}/{mode}/{partner}") { entry ->
            val id = entry.arguments?.getString("id") ?: ""
            val mode = runCatching { ScenePractice.Mode.valueOf(entry.arguments?.getString("mode") ?: "") }
                .getOrDefault(ScenePractice.Mode.AUTOMATIC)
            val asPartner = entry.arguments?.getString("partner") == "true"
            PracticeScreen(library = current.value, scenarioID = id, mode = mode, playAsPartner = asPartner, speaker = speaker,
                           listener = listener, progress = progress, prefs = prefs, learnerName = coachSettings.learnerName,
                           onBack = { navigation.popBackStack() })
        }
        composable("listen") {
            ListenScreen(library = current.value, prefs = prefs, speaker = speaker, learnerName = coachSettings.learnerName,
                         myScenes = myScenes.scenes.map { it.id }.toSet(), onBack = { navigation.popBackStack() })
        }
        composable("vocabulary") {
            VocabularyScreen(library = current.value, speaker = speaker, prefs = prefs, onBack = { navigation.popBackStack() })
        }
        composable("settings") {
            SettingsScreen(settings = coachSettings, coach = coach, onBack = { navigation.popBackStack() })
        }
        composable("myscene/new") {
            MySceneEditor(existing = null, coach = coach, settings = coachSettings, store = myScenes, listener = listener,
                          onBack = { navigation.popBackStack() },
                          onSettings = { navigation.navigate("settings") },
                          onSaved = { id ->
                              navigation.navigate("scene/$id") { popUpTo("myscene/new") { inclusive = true } }
                          })
        }
        composable("myscene/change/{id}") { entry ->
            val id = entry.arguments?.getString("id") ?: ""
            MySceneEditor(existing = myScenes.scene(id), coach = coach, settings = coachSettings, store = myScenes,
                          listener = listener, onBack = { navigation.popBackStack() },
                          onSettings = { navigation.navigate("settings") },
                          onSaved = { navigation.popBackStack() })
        }
    }
}

@Composable
private fun HomeScreen(
    speaker: Speaker,
    sceneCount: Int,
    wordCount: Int,
    onScenes: () -> Unit,
    onListen: () -> Unit,
    onVocabulary: () -> Unit,
    onSettings: () -> Unit,
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
            ListenCard(onListen)
            HomeCard(Icons.Filled.Forum, "Scenes", "$sceneCount conversations: read, hear and learn every line, or write your own", onScenes)
            HomeCard(Icons.AutoMirrored.Filled.MenuBook, "My vocabulary", "All $wordCount words in the course, with romaji", onVocabulary)
            HomeCard(Icons.Filled.RecordVoiceOver, "Speaking practice",
                     "Open a scene and tap Practise: watch, repeat, then the real conversation", onScenes)
            HomeCard(Icons.Filled.Settings, "Settings", "Your name, and the AI coach that writes your own scenes", onSettings)
        }
    }
}

/** Listen stands out: it's the one to reach for in the car, at a glance. */
@Composable
private fun ListenCard(onClick: () -> Unit) {
    val listen by ListenSession.state.collectAsState()
    val colors = MaterialTheme.colorScheme
    Card(
        onClick = onClick,
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = colors.primary, contentColor = colors.onPrimary),
    ) {
        Row(modifier = Modifier.padding(horizontal = 16.dp, vertical = 20.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Headphones, contentDescription = null, modifier = Modifier.size(40.dp))
            Spacer(Modifier.width(14.dp))
            Column {
                Text("Listen while driving", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                Text(
                    if (listen.isActive) "Playing: ${listen.sceneTitle.ifBlank { "Listen" }}"
                    else "Short scenes back to back, hands-free, with the screen off",
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
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
