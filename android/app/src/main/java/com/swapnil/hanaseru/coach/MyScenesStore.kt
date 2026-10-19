package com.swapnil.hanaseru.coach

import android.content.Context
import androidx.compose.runtime.mutableStateOf
import com.swapnil.hanaseru.content.MyScenes
import com.swapnil.hanaseru.content.SavedScene
import java.io.File

/**
 * Your own scenes, kept on the phone as one JSON file (an array of saved scenes, the shared format). Changes show
 * at once everywhere that reads [scenes].
 */
class MyScenesStore(context: Context) {
    private val file = File(context.filesDir, "my-scenes.json")
    private val saved = mutableStateOf(load())

    /** Newest first. */
    val scenes: List<SavedScene> get() = saved.value

    fun scene(id: String): SavedScene? = scenes.firstOrNull { it.id == id }

    /** Adds a scene, or replaces the one with its id. */
    fun save(scene: SavedScene) {
        update(listOf(scene) + scenes.filter { it.id != scene.id })
    }

    fun delete(id: String) {
        update(scenes.filter { it.id != id })
    }

    /** Scenes from a file; returns how many came in. */
    fun import(incoming: List<SavedScene>): Int {
        val (merged, count) = MyScenes.merge(scenes, incoming, now())
        if (count > 0) update(merged)
        return count
    }

    private fun update(list: List<SavedScene>) {
        saved.value = list
        write(list)
    }

    private fun load(): List<SavedScene> {
        if (!file.exists()) return emptyList()
        return try {
            MyScenes.decode(file.readText())
        } catch (failed: Exception) {
            // Keep an unreadable file aside rather than overwrite it with the next save.
            file.renameTo(File(file.parentFile, "my-scenes.unreadable.json"))
            emptyList()
        }
    }

    /** Written whole to a temporary file first, so a crash mid-write can't lose every scene. */
    private fun write(list: List<SavedScene>) {
        val temporary = File(file.parentFile, file.name + ".tmp")
        temporary.writeText(MyScenes.encode(list))
        if (!temporary.renameTo(file)) {
            file.writeText(MyScenes.encode(list))
            temporary.delete()
        }
    }

    companion object {
        /** Milliseconds since 1970, as the iPhone and Windows apps write it. */
        fun now(): Long = System.currentTimeMillis()
    }
}
