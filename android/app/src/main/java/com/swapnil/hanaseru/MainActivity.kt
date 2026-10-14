package com.swapnil.hanaseru

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.swapnil.hanaseru.content.ContentLibrary
import com.swapnil.hanaseru.content.JapaneseWords
import com.swapnil.hanaseru.content.Romaji
import com.swapnil.hanaseru.ui.HanaseruApp
import com.swapnil.hanaseru.ui.HanaseruTheme
import com.swapnil.hanaseru.ui.Prefs
import com.swapnil.hanaseru.voice.Speaker

class MainActivity : ComponentActivity() {
    private lateinit var speaker: Speaker

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        Romaji.wordSplitter = JapaneseWords::split
        val library = ContentLibrary.load { name -> assets.open(name).bufferedReader().use { it.readText() } }
        speaker = Speaker(this)
        val prefs = Prefs(this)
        setContent {
            HanaseruTheme {
                HanaseruApp(library = library, speaker = speaker, prefs = prefs)
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
