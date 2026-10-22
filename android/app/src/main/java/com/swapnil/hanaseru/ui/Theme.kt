package com.swapnil.hanaseru.ui

import android.content.Context
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.graphics.Color
import com.swapnil.hanaseru.listen.ListenOptions

/** The iPhone app's colours: the blue line of a Shinkansen and platform-sign amber for "your turn". */
object Palette {
    val line = Color(0xFF1C4E9B)
    val lineDark = Color(0xFF6F9CEB)
    val signal = Color(0xFFC98A00)
    val signalDark = Color(0xFFF2B63A)
    val go = Color(0xFF2B7A4B)
}

@Composable
fun HanaseruTheme(content: @Composable () -> Unit) {
    val colors = if (isSystemInDarkTheme()) {
        darkColorScheme(
            primary = Palette.lineDark,
            secondary = Palette.signalDark,
            background = Color(0xFF0B111A),
            surface = Color(0xFF141C28),
            surfaceVariant = Color(0xFF1B2533),
            onBackground = Color(0xFFECEFF4),
            onSurface = Color(0xFFECEFF4),
            onSurfaceVariant = Color(0xFF9BA6B5),
        )
    } else {
        lightColorScheme(
            primary = Palette.line,
            secondary = Palette.signal,
            background = Color(0xFFF4F3EE),
            surface = Color(0xFFFFFFFF),
            surfaceVariant = Color(0xFFEAE8E1),
            onBackground = Color(0xFF111827),
            onSurface = Color(0xFF111827),
            onSurfaceVariant = Color(0xFF596373),
        )
    }
    MaterialTheme(colorScheme = colors, content = content)
}

/** Display choices, kept between launches. */
class Prefs(context: Context) {
    private val store = context.getSharedPreferences("hanaseru", Context.MODE_PRIVATE)
    private val english = mutableStateOf(store.getBoolean("showEnglish", true))
    private val romaji = mutableStateOf(store.getBoolean("showRomaji", false))
    private val fieldChoice = mutableStateOf(store.getString("workField", "engineering") ?: "engineering")

    /** "engineering" or "finance": whose work scenes come first. */
    var workField: String
        get() = fieldChoice.value
        set(value) {
            fieldChoice.value = value
            store.edit().putString("workField", value).apply()
        }

    var showEnglish: Boolean
        get() = english.value
        set(value) {
            english.value = value
            store.edit().putBoolean("showEnglish", value).apply()
        }

    var showRomaji: Boolean
        get() = romaji.value
        set(value) {
            romaji.value = value
            store.edit().putBoolean("showRomaji", value).apply()
        }

    private val listenChoices = mutableStateOf(readListenOptions())

    /** Listen's choices (language, length, scenes, speed), as last used. */
    var listenOptions: ListenOptions
        get() = listenChoices.value
        set(value) {
            listenChoices.value = value
            store.edit()
                .putString("listenLanguage", value.language.name)
                .putString("listenLength", value.length.name)
                .putString("listenSource", value.source.name)
                .putString("listenSpeed", value.speed.name)
                .apply()
        }

    private fun readListenOptions(): ListenOptions {
        val defaults = ListenOptions()
        return ListenOptions(
            language = choice("listenLanguage", defaults.language),
            length = choice("listenLength", defaults.length),
            source = choice("listenSource", defaults.source),
            speed = choice("listenSpeed", defaults.speed),
        )
    }

    /** A stored enum, or the default when it's missing or from another version. */
    private inline fun <reified T : Enum<T>> choice(key: String, default: T): T {
        val name = store.getString(key, null) ?: return default
        return enumValues<T>().firstOrNull { it.name == name } ?: default
    }
}
