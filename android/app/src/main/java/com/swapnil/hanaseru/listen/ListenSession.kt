package com.swapnil.hanaseru.listen

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** What Listen is doing, for the screen, the notification and the lock screen. */
data class ListenState(
    val status: Status = Status.IDLE,
    /** 1-based; 0 before the first scene. */
    val sceneNumber: Int = 0,
    val sceneCount: Int = 0,
    val sceneTitle: String = "",
    val sceneTitleJa: String = "",
    /** The line being said (or, when paused, the one that plays again on Play). */
    val line: ListenUtterance? = null,
    /** Why it paused, when it wasn't you. */
    val message: String = "",
) {
    enum class Status { IDLE, PLAYING, PAUSED, FINISHED }

    /** Playing or paused: there is something to carry on with. */
    val isActive: Boolean get() = status == Status.PLAYING || status == Status.PAUSED
}

/**
 * The link between the Listen screen and the playback service (one process, so a singleton is enough): the screen
 * hands over the playlist to play and watches [state]; the service does the rest.
 */
object ListenSession {
    private val mutableState = MutableStateFlow(ListenState())
    val state: StateFlow<ListenState> = mutableState

    /** The playlist the service picks up when it is started. */
    @Volatile internal var pending: Playlist? = null

    internal fun update(state: ListenState) {
        mutableState.value = state
    }
}

/** The ids of the last 30 scenes played in Listen, oldest first, kept between launches. */
class ListenHistory(context: Context) {
    private val store = context.applicationContext.getSharedPreferences("hanaseru", Context.MODE_PRIVATE)

    val recent: List<String>
        get() = (store.getString(KEY, "") ?: "").split('\n').filter { it.isNotBlank() }

    fun played(id: String) {
        store.edit().putString(KEY, ListenPlaylist.remember(recent, id).joinToString("\n")).apply()
    }

    private companion object {
        const val KEY = "listenRecent"
    }
}
