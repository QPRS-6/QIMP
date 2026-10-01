package com.qprs.musicplayer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import androidx.core.app.NotificationCompat
import androidx.media.app.NotificationCompat.MediaStyle
import androidx.media.session.MediaButtonReceiver

/**
 * 播放的前台服务：把「正在播放」提升成前台服务，并提供锁屏 / 通知栏 / 耳机按键控制。
 *
 * 设计上的两个关键点：
 *
 * 1. **命令走 JNI 直接进 Rust，不经过 Dart**。Flutter 引擎随 Activity 销毁，用户把 App
 *    从任务列表划掉之后 Dart 侧就没了；此时播放线程和这个服务还在，通知栏上的按钮
 *    必须照样能用。所以这里调 [PlaybackBridge]，而不是往 Flutter 发消息。
 *
 * 2. **状态由 Rust 说了算**。本服务只做两件事：每 [POLL_INTERVAL_MS] 毫秒读一次
 *    Rust 的快照（状态 / 位置 / 曲目），把结果翻译成 `MediaSessionCompat` 与通知；
 *    以及把用户按下的按钮转发回 Rust。自己**不保存任何播放状态**，避免两份真相。
 *
 * 生命周期：Dart 侧在开始播放时 `startForegroundService`；Rust 报「已停止」若干轮之后
 * 服务自己收掉（通知随之消失）。暂停时服务继续留着，这样从锁屏能直接恢复播放。
 */
class PlaybackService : Service() {

    private lateinit var session: MediaSessionCompat
    private val handler = Handler(Looper.getMainLooper())

    /** 轮询循环是否还在跑（`stopSelf` 之后就不再排队）。 */
    private var polling = false

    /** 连续多少次读到「已停止」/「失败」，用来决定何时收掉服务。 */
    private var idleTicks = 0

    /** 当前曲目信息的缓存：只有曲目变了才去查曲库，轮询本身只读几个原子量。 */
    private var cachedTrackId = 0L
    private var title = ""
    private var artist = ""
    private var durationMs = 0L
    private var errorText = ""

    /** 上一次画出的「状态 + 曲目」：用来判断要不要重发通知。 */
    private var lastSignature = ""

    /**
     * 音量归零 / 蓝牙断开 → 自动暂停。盯着系统事件，只在真在播时才动手，
     * 细节见 [PlaybackAutoStop]。
     */
    private lateinit var autoStop: PlaybackAutoStop

    private val ticker = object : Runnable {
        override fun run() {
            if (!polling) return
            runCatching { refresh() }
            if (polling) handler.postDelayed(this, POLL_INTERVAL_MS)
        }
    }

    /** 按键 / 蓝牙 / 锁屏上的操作：一律转发给 Rust。 */
    private val sessionCallback = object : MediaSessionCompat.Callback() {
        override fun onPlay() {
            PlaybackBridge.play()
        }

        override fun onPause() {
            PlaybackBridge.pause()
        }

        override fun onSkipToNext() {
            PlaybackBridge.next()
        }

        override fun onSkipToPrevious() {
            PlaybackBridge.previous()
        }

        override fun onSeekTo(pos: Long) {
            PlaybackBridge.seekTo(pos)
        }

        override fun onStop() {
            PlaybackBridge.stop()
            stopSelf()
        }
    }

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
        session = MediaSessionCompat(this, "qprs-musicplayer").apply {
            setCallback(sessionCallback)
            setFlags(
                MediaSessionCompat.FLAG_HANDLES_MEDIA_BUTTONS or
                    MediaSessionCompat.FLAG_HANDLES_TRANSPORT_CONTROLS,
            )
            // 锁屏 / 车机从这里回到 App。
            setSessionActivity(contentIntent())
            isActive = true
        }
        polling = true
        handler.post(ticker)
        // 自动暂停放在服务里而不是 Activity 里：它盯的是系统事件，与 Flutter 引擎在不在无关。
        autoStop = PlaybackAutoStop(
            context = applicationContext,
            isPlaying = { PlaybackBridge.stateCode() == PlaybackBridge.STATE_PLAYING },
            pause = { PlaybackBridge.pause() },
        ).apply { start() }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PLAY -> PlaybackBridge.play()
            ACTION_PAUSE -> PlaybackBridge.pause()
            ACTION_TOGGLE -> PlaybackBridge.toggle()
            ACTION_NEXT -> PlaybackBridge.next()
            ACTION_PREVIOUS -> PlaybackBridge.previous()
            ACTION_STOP -> {
                PlaybackBridge.stop()
                stopSelf()
                return START_NOT_STICKY
            }
            // 耳机 / 蓝牙的按键事件（服务被系统重新拉起时也走这里）。
            Intent.ACTION_MEDIA_BUTTON -> MediaButtonReceiver.handleIntent(session, intent)
            else -> Unit // Dart 侧只是来「启动服务」
        }

        // 通知必须尽快挂上去：startForegroundService 有 5 秒的硬时限。
        refresh()
        promoteToForeground()
        return START_STICKY
    }

    /**
     * 本服务不对外提供绑定：会话是由通知（MediaStyle 里的 token）暴露给系统的，
     * 耳机按键则由 [MediaButtonReceiver] 依清单里的 MediaBrowserService 过滤器找回本服务
     * （见 `onStartCommand` 里的 `ACTION_MEDIA_BUTTON` 分支）。所以这里返回 null 即可。
     */
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        polling = false
        handler.removeCallbacks(ticker)
        // 先摘掉监听：服务没了就别再有人来碰播放。
        autoStop.stop()
        session.isActive = false
        session.release()
        super.onDestroy()
    }

    // ------------------------------------------------------------------
    // 状态同步
    // ------------------------------------------------------------------

    private fun refresh() {
        // 引擎还没打开（比如进程被系统重启、服务先醒过来）：此时没有任何可显示的内容。
        if (!PlaybackBridge.engineReady()) {
            stopSelf()
            return
        }

        val state = PlaybackBridge.stateCode()
        val positionMs = PlaybackBridge.positionMs().coerceAtLeast(0L)
        val trackId = PlaybackBridge.trackId()
        if (trackId != cachedTrackId) {
            cachedTrackId = trackId
            title = PlaybackBridge.trackTitle().orEmpty()
            artist = PlaybackBridge.trackArtist().orEmpty()
            durationMs = PlaybackBridge.trackDurationMs().coerceAtLeast(0L)
        }
        errorText = if (state == PlaybackBridge.STATE_FAILED) {
            PlaybackBridge.errorText().orEmpty()
        } else {
            ""
        }

        session.setMetadata(metadata())
        // speed 传 1：让系统自己把进度条往前推，不然得靠我们每 500ms 重发一次通知。
        session.setPlaybackState(playbackState(state, positionMs))

        val signature = "$state|$trackId|$errorText"
        if (signature != lastSignature) {
            lastSignature = signature
            notify(notification(state))
        }

        // 播完了 / 播挂了就收掉服务：通知不该在什么都没播的时候赖着不走。
        when (state) {
            PlaybackBridge.STATE_STOPPED -> {
                idleTicks += 1
                if (idleTicks >= IDLE_TICKS_BEFORE_STOP) stopSelf()
            }
            PlaybackBridge.STATE_FAILED -> {
                idleTicks += 1
                if (idleTicks >= FAILED_TICKS_BEFORE_STOP) stopSelf()
            }
            else -> idleTicks = 0
        }
    }

    private fun metadata(): MediaMetadataCompat = MediaMetadataCompat.Builder()
        .putString(MediaMetadataCompat.METADATA_KEY_TITLE, displayTitle())
        .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, artist)
        .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, durationMs)
        .build()

    private fun playbackState(state: Int, positionMs: Long): PlaybackStateCompat {
        val actions = PlaybackStateCompat.ACTION_PLAY or
            PlaybackStateCompat.ACTION_PAUSE or
            PlaybackStateCompat.ACTION_PLAY_PAUSE or
            PlaybackStateCompat.ACTION_SKIP_TO_NEXT or
            PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS or
            PlaybackStateCompat.ACTION_SEEK_TO or
            PlaybackStateCompat.ACTION_STOP
        val stateCode = when (state) {
            PlaybackBridge.STATE_PLAYING -> PlaybackStateCompat.STATE_PLAYING
            PlaybackBridge.STATE_PAUSED -> PlaybackStateCompat.STATE_PAUSED
            PlaybackBridge.STATE_FAILED -> PlaybackStateCompat.STATE_ERROR
            else -> PlaybackStateCompat.STATE_STOPPED
        }
        return PlaybackStateCompat.Builder()
            .setActions(actions)
            .setState(stateCode, positionMs, if (state == PlaybackBridge.STATE_PLAYING) 1f else 0f)
            .build()
    }

    private fun displayTitle(): String = when {
        title.isNotEmpty() -> title
        cachedTrackId <= 0 -> "本地音乐播放器"
        else -> "未知曲目"
    }

    // ------------------------------------------------------------------
    // 通知
    // ------------------------------------------------------------------

    private fun notification(state: Int): Notification {
        val playing = state == PlaybackBridge.STATE_PLAYING
        val text = when {
            errorText.isNotEmpty() -> "播不了：$errorText"
            playing -> artist.ifEmpty { "正在播放" }
            state == PlaybackBridge.STATE_PAUSED -> "已暂停"
            else -> ""
        }
        val style = MediaStyle()
            .setMediaSession(session.sessionToken)
            .setShowActionsInCompactView(0, 1, 2)

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(displayTitle())
            .setContentText(text)
            .setContentIntent(contentIntent())
            // 划掉通知 = 停止播放，比留一个没有意义的空通知好。
            .setDeleteIntent(actionIntent(ACTION_STOP, REQUEST_STOP))
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setOngoing(playing)
            .addAction(
                NotificationCompat.Action(
                    android.R.drawable.ic_media_previous,
                    "上一首",
                    actionIntent(ACTION_PREVIOUS, REQUEST_PREVIOUS),
                ),
            )
            .addAction(
                NotificationCompat.Action(
                    if (playing) {
                        android.R.drawable.ic_media_pause
                    } else {
                        android.R.drawable.ic_media_play
                    },
                    if (playing) "暂停" else "播放",
                    actionIntent(ACTION_TOGGLE, REQUEST_TOGGLE),
                ),
            )
            .addAction(
                NotificationCompat.Action(
                    android.R.drawable.ic_media_next,
                    "下一首",
                    actionIntent(ACTION_NEXT, REQUEST_NEXT),
                ),
            )
            .setStyle(style)
            .build()
    }

    private fun notify(notification: Notification) {
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification)
    }

    private fun promoteToForeground() {
        val notification = notification(PlaybackBridge.stateCode())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun ensureChannel() {
        val manager = getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "播放控制",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "显示正在播放的歌曲，并提供播放控制"
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }
    }

    private fun contentIntent(): PendingIntent = PendingIntent.getActivity(
        this,
        REQUEST_CONTENT,
        Intent(this, MainActivity::class.java).setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    /** 通知上的按钮：用 PendingIntent 回到本服务的 `onStartCommand`。 */
    private fun actionIntent(action: String, requestCode: Int): PendingIntent =
        PendingIntent.getService(
            this,
            requestCode,
            Intent(this, PlaybackService::class.java).setAction(action),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

    companion object {
        /** Dart 侧启动服务用（保持前台 + 显示通知）。 */
        const val ACTION_START = "com.qprs.musicplayer.action.START"

        private const val ACTION_PLAY = "com.qprs.musicplayer.action.PLAY"
        private const val ACTION_PAUSE = "com.qprs.musicplayer.action.PAUSE"
        private const val ACTION_TOGGLE = "com.qprs.musicplayer.action.TOGGLE"
        private const val ACTION_NEXT = "com.qprs.musicplayer.action.NEXT"
        private const val ACTION_PREVIOUS = "com.qprs.musicplayer.action.PREVIOUS"
        private const val ACTION_STOP = "com.qprs.musicplayer.action.STOP"

        private const val CHANNEL_ID = "playback"
        private const val NOTIFICATION_ID = 1001

        private const val REQUEST_CONTENT = 10
        private const val REQUEST_PREVIOUS = 11
        private const val REQUEST_TOGGLE = 12
        private const val REQUEST_NEXT = 13
        private const val REQUEST_STOP = 14

        /** 状态轮询间隔：通知的进度由系统自己外推，这里只要跟得上切歌。 */
        private const val POLL_INTERVAL_MS = 500L

        /** 连续这么多次（约 2 秒）读到「已停止」就收掉服务。 */
        private const val IDLE_TICKS_BEFORE_STOP = 4

        /** 失败原因多留一会儿（约 3 秒），让人来得及看到通知上的提示。 */
        private const val FAILED_TICKS_BEFORE_STOP = 6
    }
}
