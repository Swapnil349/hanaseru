package com.swapnil.hanaseru

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.swapnil.hanaseru.coach.CoachClient
import com.swapnil.hanaseru.coach.CoachSettings
import com.swapnil.hanaseru.coach.MyScenesStore
import com.swapnil.hanaseru.content.ContentLibrary
import com.swapnil.hanaseru.content.JapaneseWords
import com.swapnil.hanaseru.content.Romaji
import com.swapnil.hanaseru.practice.Progress
import com.swapnil.hanaseru.ui.HanaseruApp
import com.swapnil.hanaseru.ui.HanaseruTheme
import com.swapnil.hanaseru.ui.Prefs
import com.swapnil.hanaseru.voice.AudioFocus
import com.swapnil.hanaseru.voice.Listener
import com.swapnil.hanaseru.voice.Speaker

class MainActivity : ComponentActivity() {
    private lateinit var speaker: Speaker

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        Romaji.wordSplitter = JapaneseWords::split
        val library = ContentLibrary.load { name -> assets.open(name).bufferedReader().use { it.readText() } }
        // Speaking and listening share the phone's sound.
        val focus = AudioFocus(this)
        speaker = Speaker(this, focus)
        val prefs = Prefs(this)
        val listener = Listener(this, focus)
        val progress = Progress(this)
        val coachSettings = CoachSettings(this)
        val coach = CoachClient(coachSettings)
        val myScenes = MyScenesStore(this)
        setContent {
            HanaseruTheme {
                HanaseruApp(library = library, speaker = speaker, listener = listener, progress = progress, prefs = prefs,
                            coachSettings = coachSettings, coach = coach, myScenes = myScenes)
            }
        }
    }

    override fun onStop() {
        super.onStop()
        speaker.stop()
    }

    override fun onDestroy() {
        super.onDestroy()
        speaker.shutdown()
    }
}
