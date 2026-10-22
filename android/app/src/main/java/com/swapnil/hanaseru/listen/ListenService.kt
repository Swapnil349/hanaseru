package com.swapnil.hanaseru.listen

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.swapnil.hanaseru.R
import com.swapnil.hanaseru.listen.ListenState.Status
import com.swapnil.hanaseru.voice.AudioFocus
import com.swapnil.hanaseru.voice.Speaker
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Plays a Listen playlist with the screen off: a foreground media-playback service with its own voice, a media
 * session (headphone and Bluetooth buttons, car controls, the lock screen) and a media notification.
 *
 * It keeps its place as (scene, line). Pausing stops the line; playing again says that line from its start. A phone
 * call or another app's short sound pauses it and it carries on afterwards; another app playing for good, or
 * headphones coming out, pause it until you press Play. Everything runs on the main thread.
 */
class ListenService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val main = Handler(Looper.getMainLooper())
    private lateinit var focus: AudioFocus
    private lateinit var speaker: Speaker
    private lateinit var session: MediaSessionCompat
    private lateinit var history: ListenHistory

    private var playlist: Playlist? = null
    private var sceneIndex = 0
    private var lineIndex = 0
    private var job: Job? = null
    private var state = ListenState()

    /** When the current scene started playing, to tell "restart this scene" from "the scene before". */
    private var sceneStartedAt = 0L
    private var pausedIntoScene = 0L

    /** This service's own hold on the sound, kept from Play to Pause so it isn't given up between lines. */
    private var holdingFocus = false
    /** Paused by a phone call or another app's short sound: carry on when the sound comes back. */
    private var resumeOnFocusGain = false
    private var foreground = false
    private var noisyRegistered = false
    /**
     * Keeps the phone awake while it plays, so the pauses between lines don't stretch or stall with the screen
     * off (driving). Held only while playing; a time limit guards against ever leaving it held.
     */
    private val wakeLock: PowerManager.WakeLock by lazy {
        (getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "hanaseru:listen")
            .apply { setReferenceCounted(false) }
    }

    private val noisy = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            // Headphones or Bluetooth disconnected: don't carry on out of the phone's speaker.
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) pause()
        }
    }

    /** Paused for a while: the notification may be swiped away and the service may end. */
    private val leaveForeground = Runnable {
        if (state.status != Status.PLAYING) {
            if (holdingFocus) {
                holdingFocus = false
                resumeOnFocusGain = false
                focus.release()
            }
            stopForegroundCompat(remove = false)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        history = ListenHistory(this)
        focus = AudioFocus(this, AudioManager.AUDIOFOCUS_GAIN)
        speaker = Speaker(this, focus)
        // The voice watches the sound for its line; this service watches it to pause and carry on.
        val speakerWatch = focus.onChange
        focus.onChange = { change ->
            speakerWatch?.invoke(change)
            focusChanged(change)
        }
        speaker.onFocusLost = { pause(byFocus = true, message = "Paused: another app is using the sound.") }

        session = MediaSessionCompat(this, "HanaseruListen").apply {
            setCallback(object : MediaSessionCompat.Callback() {
                override fun onPlay() = play()
                override fun onPause() = pause()
                override fun onSkipToNext() = next()
                override fun onSkipToPrevious() = previous()
                override fun onStop() = stopListening()
            })
            setSessionActivity(openAppIntent())
        }
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        if (action == ACTION_START) {
            val next = ListenSession.pending
            ListenSession.pending = null
            if (next != null && next.scenes.isNotEmpty()) {
                start(next)
            } else {
                // Started with nothing to play: it must still go to the foreground before it ends.
                startForegroundCompat()
                stopListening()
            }
        } else if (playlist == null) {
            // A notification button after the app was closed: nothing left to play.
            stopListening()
        } else {
            when (action) {
                ACTION_TOGGLE -> if (state.status == Status.PLAYING) pause() else play()
                ACTION_PLAY -> play()
                ACTION_PAUSE -> pause()
                ACTION_NEXT -> next()
                ACTION_PREVIOUS -> previous()
                ACTION_STOP -> stopListening()
            }
        }
        // Not restarted by the system: the playlist lives only in memory.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        if (wakeLock.isHeld) wakeLock.release()
        job?.cancel()
        scope.cancel()
        main.removeCallbacks(leaveForeground)
        unregisterNoisy()
        if (holdingFocus) focus.release()
        holdingFocus = false
        speaker.stop()
        speaker.shutdown()
        // Ended by the system: the screen shouldn't show it still playing.
        if (state.isActive) {
            state = ListenState()
            ListenSession.update(state)
        }
        session.isActive = false
        session.release()
        super.onDestroy()
    }

    // MARK: Controls

    private fun start(next: Playlist) {
        playlist = next
        sceneIndex = 0
        lineIndex = 0
        pausedIntoScene = 0L
        state = ListenState(sceneCount = next.scenes.size)
        session.isActive = true
        startForegroundCompat()
        play()
    }

    private fun play() {
        val current = playlist ?: return stopListening()
        if (state.status == Status.PLAYING) return
        if (state.status == Status.FINISHED || sceneIndex > current.scenes.size) {
            sceneIndex = 0
            lineIndex = 0
            pausedIntoScene = 0L
        }
        main.removeCallbacks(leaveForeground)
        resumeOnFocusGain = false
        if (!holdingFocus) {
            holdingFocus = true
            focus.acquire()
        }
        registerNoisy()
        session.isActive = true
        sceneStartedAt = SystemClock.elapsedRealtime() - pausedIntoScene
        // Playing at once, so a Pause pressed straight after isn't lost.
        publish(state.copy(status = Status.PLAYING, message = ""))
        startForegroundCompat()
        launch()
    }

    /**
     * Stops the line and keeps the place. A pause that isn't yours (a call) keeps the hold on the sound, so playing
     * carries on when it comes back.
     */
    private fun pause(byFocus: Boolean = false, message: String = "") {
        if (state.status != Status.PLAYING) {
            if (!byFocus) resumeOnFocusGain = false
            return
        }
        job?.cancel()
        job = null
        speaker.stop()
        pausedIntoScene = SystemClock.elapsedRealtime() - sceneStartedAt
        unregisterNoisy()
        resumeOnFocusGain = byFocus
        if (!byFocus && holdingFocus) {
            holdingFocus = false
            focus.release()
        }
        publish(state.copy(status = Status.PAUSED, message = message))
        main.removeCallbacks(leaveForeground)
        main.postDelayed(leaveForeground, PAUSED_FOREGROUND_MILLIS)
    }

    private fun next() {
        val current = playlist ?: return
        if (sceneIndex >= current.scenes.size) return finish()
        sceneIndex++
        lineIndex = 0
        pausedIntoScene = 0L
        restartPlaying()
    }

    private fun previous() {
        val current = playlist ?: return
        val into = if (state.status == Status.PLAYING) SystemClock.elapsedRealtime() - sceneStartedAt else pausedIntoScene
        sceneIndex = ListenPlaylist.previousScene(sceneIndex, into, current.scenes.size)
        lineIndex = 0
        pausedIntoScene = 0L
        restartPlaying()
    }

    /** After Next or Previous: play from the new place (a driver pressing a button wants to hear something). */
    private fun restartPlaying() {
        if (state.status == Status.PLAYING) {
            sceneStartedAt = SystemClock.elapsedRealtime()
            launch()
        } else {
            if (state.status == Status.FINISHED) state = state.copy(status = Status.PAUSED)
            play()
        }
    }

    private fun stopListening() {
        job?.cancel()
        job = null
        speaker.stop()
        playlist = null
        unregisterNoisy()
        if (holdingFocus) {
            holdingFocus = false
            focus.release()
        }
        main.removeCallbacks(leaveForeground)
        publish(ListenState())
        session.isActive = false
        stopForegroundCompat(remove = true)
        stopSelf()
    }

    private fun finish() {
        job?.cancel()
        job = null
        unregisterNoisy()
        if (holdingFocus) {
            holdingFocus = false
            focus.release()
        }
        sceneIndex = (playlist?.scenes?.size ?: 0) + 1
        publish(state.copy(status = Status.FINISHED, line = null, message = ""))
        session.isActive = false
        stopForegroundCompat(remove = true)
        stopSelf()
    }

    private fun focusChanged(change: Int) {
        when (change) {
            // A call, or a navigation prompt that asks for the sound: carry on afterwards.
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> pause(byFocus = true, message = "Paused for another sound.")
            // Another app is playing now: wait for you.
            AudioManager.AUDIOFOCUS_LOSS -> {
                pause(message = "Paused: another app is playing.")
                resumeOnFocusGain = false
                if (holdingFocus) {
                    holdingFocus = false
                    focus.release()
                }
            }
            AudioManager.AUDIOFOCUS_GAIN -> if (resumeOnFocusGain && state.status == Status.PAUSED) play()
        }
    }

    // MARK: Playing

    private fun launch() {
        val previous = job
        previous?.cancel()
        job = scope.launch {
            // Let the stopped line wind down (it stops only its own speech), but never wait long.
            if (previous != null) withTimeoutOrNull(1_500) { previous.join() }
            run()
        }
    }

    private suspend fun run() {
        val current = playlist ?: return
        while (true) {
            val scene = current.scenes.getOrNull(sceneIndex)
            val lines = scene?.utterances ?: current.ending
            if (lineIndex >= lines.size) {
                if (scene == null) break
                sceneIndex++
                lineIndex = 0
                sceneStartedAt = SystemClock.elapsedRealtime()
                continue
            }
            if (scene != null && lineIndex == 0) history.played(scene.id)
            val line = lines[lineIndex]
            publish(ListenState(
                status = Status.PLAYING,
                sceneNumber = if (scene == null) current.scenes.size else sceneIndex + 1,
                sceneCount = current.scenes.size,
                sceneTitle = scene?.title ?: "The end",
                sceneTitleJa = scene?.titleJa ?: "おしまい",
                line = line,
            ))
            speaker.speak(line.text, voice(line.voice), line.rate)
            // Paused while it spoke: keep this line, to say again on Play.
            currentCoroutineContext().ensureActive()
            lineIndex++
            delay(line.pauseAfterMillis)
        }
        finish()
    }

    private fun voice(voice: ListenVoice): Speaker.Voice = when (voice) {
        ListenVoice.COACH_JAPANESE -> Speaker.Voice.COACH_JAPANESE
        ListenVoice.PARTNER_MALE -> Speaker.Voice.PARTNER_MALE
        ListenVoice.PARTNER_FEMALE -> Speaker.Voice.PARTNER_FEMALE
        ListenVoice.ENGLISH -> Speaker.Voice.ENGLISH
    }

    // MARK: What everyone sees

    private fun publish(next: ListenState) {
        val titleChanged = next.sceneTitle != state.sceneTitle || next.sceneNumber != state.sceneNumber
        val statusChanged = next.status != state.status
        state = next
        ListenSession.update(next)
        if (next.status == Status.PLAYING) {
            if (!wakeLock.isHeld) wakeLock.acquire(WAKE_LOCK_MILLIS)
        } else if (wakeLock.isHeld) {
            wakeLock.release()
        }
        if (titleChanged) updateMetadata()
        if (statusChanged || titleChanged) {
            updatePlaybackState()
            if (next.isActive) notifyNow()
        }
    }

    private fun updateMetadata() {
        val metadata = MediaMetadataCompat.Builder()
            .putString(MediaMetadataCompat.METADATA_KEY_TITLE, state.sceneTitle.ifBlank { "Listen" })
            .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, ARTIST)
            .putString(MediaMetadataCompat.METADATA_KEY_ALBUM, sceneLabel())
            .build()
        session.setMetadata(metadata)
    }

    private fun updatePlaybackState() {
        val playbackState = when (state.status) {
            Status.PLAYING -> PlaybackStateCompat.STATE_PLAYING
            Status.PAUSED -> PlaybackStateCompat.STATE_PAUSED
            Status.FINISHED, Status.IDLE -> PlaybackStateCompat.STATE_STOPPED
        }
        session.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setActions(
                    PlaybackStateCompat.ACTION_PLAY or PlaybackStateCompat.ACTION_PAUSE or
                        PlaybackStateCompat.ACTION_PLAY_PAUSE or PlaybackStateCompat.ACTION_SKIP_TO_NEXT or
                        PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS or PlaybackStateCompat.ACTION_STOP
                )
                .setState(playbackState, PlaybackStateCompat.PLAYBACK_POSITION_UNKNOWN, 1f)
                .build()
        )
    }

    private fun sceneLabel(): String =
        if (state.sceneNumber > 0) "Scene ${state.sceneNumber} of ${state.sceneCount}" else "Hanaseru"

    private fun createChannel() {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(CHANNEL, "Listen", NotificationManager.IMPORTANCE_LOW).apply {
            description = "What Listen is playing, with Play, Pause and Next"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun notification(): Notification {
        val playing = state.status == Status.PLAYING
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_listen)
            .setContentTitle(state.sceneTitle.ifBlank { "Listen" })
            .setContentText("$ARTIST · ${sceneLabel()}")
            .setContentIntent(openAppIntent())
            .setDeleteIntent(command(ACTION_STOP))
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setCategory(NotificationCompat.CATEGORY_TRANSPORT)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setOngoing(playing)
            .addAction(R.drawable.ic_previous, "Previous scene", command(ACTION_PREVIOUS))
            .addAction(
                if (playing) R.drawable.ic_pause else R.drawable.ic_play,
                if (playing) "Pause" else "Play",
                command(ACTION_TOGGLE),
            )
            .addAction(R.drawable.ic_next, "Next scene", command(ACTION_NEXT))
            .setStyle(
                androidx.media.app.NotificationCompat.MediaStyle()
                    .setMediaSession(session.sessionToken)
                    .setShowActionsInCompactView(0, 1, 2)
            )
            .build()
    }

    private fun notifyNow() {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        // Without permission to post (Android 13+), the media controls still work; nothing to show.
        runCatching { manager.notify(NOTIFICATION_ID, notification()) }
    }

    /** Called again while already in the foreground, it just updates the notification (and answers every start). */
    private fun startForegroundCompat() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
            } else {
                startForeground(NOTIFICATION_ID, notification())
            }
            foreground = true
        } catch (refused: Exception) {
            // Android 12+ can refuse from the background (a long pause, then Play from the car): play anyway.
            notifyNow()
        }
    }

    private fun stopForegroundCompat(remove: Boolean) {
        if (foreground) {
            stopForeground(if (remove) STOP_FOREGROUND_REMOVE else STOP_FOREGROUND_DETACH)
            foreground = false
        }
        val manager = getSystemService(NotificationManager::class.java)
        if (remove) {
            manager?.cancel(NOTIFICATION_ID)
        } else if (state.isActive) {
            notifyNow()
        }
    }

    private fun registerNoisy() {
        if (noisyRegistered) return
        ContextCompat.registerReceiver(this, noisy, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY),
                                       ContextCompat.RECEIVER_NOT_EXPORTED)
        noisyRegistered = true
    }

    private fun unregisterNoisy() {
        if (!noisyRegistered) return
        runCatching { unregisterReceiver(noisy) }
        noisyRegistered = false
    }

    private fun command(action: String): PendingIntent = PendingIntent.getService(
        this, action.hashCode(), Intent(this, ListenService::class.java).setAction(action),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    /** Brings the app back as it was (not a second copy of it). */
    private fun openAppIntent(): PendingIntent {
        val open = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent().setClassName(this, "com.swapnil.hanaseru.MainActivity")
        open.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
        return PendingIntent.getActivity(this, 0, open, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    companion object {
        private const val CHANNEL = "listen"
        private const val NOTIFICATION_ID = 42
        private const val ARTIST = "Hanaseru · Listen"

        /** Paused this long, the notification can be swiped away and the sound is given back. */
        private const val PAUSED_FOREGROUND_MILLIS = 10 * 60 * 1000L
        /** A 10-scene playlist is well under an hour; the lock is renewed on every Play anyway. */
        private const val WAKE_LOCK_MILLIS = 60 * 60 * 1000L

        const val ACTION_START = "com.swapnil.hanaseru.listen.START"
        const val ACTION_TOGGLE = "com.swapnil.hanaseru.listen.TOGGLE"
        const val ACTION_PLAY = "com.swapnil.hanaseru.listen.PLAY"
        const val ACTION_PAUSE = "com.swapnil.hanaseru.listen.PAUSE"
        const val ACTION_NEXT = "com.swapnil.hanaseru.listen.NEXT"
        const val ACTION_PREVIOUS = "com.swapnil.hanaseru.listen.PREVIOUS"
        const val ACTION_STOP = "com.swapnil.hanaseru.listen.STOP"

        /** Plays a playlist from its start (replacing anything playing). */
        fun start(context: Context, playlist: Playlist) {
            ListenSession.pending = playlist
            ContextCompat.startForegroundService(context, Intent(context, ListenService::class.java).setAction(ACTION_START))
        }

        /** Play/Pause, Next, Previous or Stop from the screen. Does nothing when Listen isn't running. */
        fun send(context: Context, action: String) {
            if (!ListenSession.state.value.isActive) return
            runCatching { context.startService(Intent(context, ListenService::class.java).setAction(action)) }
        }

        /** Practice is starting: Listen stops, so the two never talk over each other. */
        fun stopIfPlaying(context: Context) = send(context, ACTION_STOP)
    }
}
