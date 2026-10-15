package com.swapnil.hanaseru.practice

import android.content.Context

/** Which lines you've said well and which scenes you've practised, kept between launches. */
class Progress(context: Context) {
    private val store = context.getSharedPreferences("progress", Context.MODE_PRIVATE)

    fun isKnown(lineID: String): Boolean = lineID in (store.getStringSet(KNOWN, null) ?: emptySet())

    fun markKnown(lineID: String) {
        val known = (store.getStringSet(KNOWN, null) ?: emptySet()).toMutableSet()
        if (known.add(lineID)) store.edit().putStringSet(KNOWN, known).apply()
    }

    fun hasPractised(scenarioID: String): Boolean = scenarioID in (store.getStringSet(SCENES, null) ?: emptySet())

    fun markPractised(scenarioID: String) {
        val scenes = (store.getStringSet(SCENES, null) ?: emptySet()).toMutableSet()
        if (scenes.add(scenarioID)) store.edit().putStringSet(SCENES, scenes).apply()
    }

    private companion object {
        const val KNOWN = "knownLines"
        const val SCENES = "practisedScenes"
    }
}
