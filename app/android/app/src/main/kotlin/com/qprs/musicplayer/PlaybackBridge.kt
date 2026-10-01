package com.qprs.musicplayer

/**
 * Rust 侧的播放接口（JNI）。
 *
 * 为什么不走 Flutter 的 MethodChannel：Flutter 引擎随 Activity 一起销毁，用户把 App
 * 从任务列表划掉之后 Dart 侧就不在了，但播放和通知栏按钮还得照常工作。
 * 这些方法直接落到 Rust 的全局引擎上（与 FRB 用的是同一份状态）。
 *
 * 符号名在 Rust 侧拼成 `Java_com_qprs_musicplayer_PlaybackBridge_<方法名>`，
 * 所以**改包名 / 类名 / 方法名都必须同步改 `rust/ffi/src/api/native.rs`**——
 * 错了不是编译错误，是运行时的 `UnsatisfiedLinkError`。
 */
internal object PlaybackBridge {
    init {
        // 与 flutter_rust_bridge 加载的是同一个 .so，重复加载没有副作用。
        System.loadLibrary("musicplayer_ffi")
    }

    /** 与 Rust 侧 `playback_bridge::STATE_*` 常量一一对应。 */
    const val STATE_STOPPED = 0
    const val STATE_PLAYING = 1
    const val STATE_PAUSED = 2
    const val STATE_FAILED = 3

    /** 引擎是否已经打开。App 还没走到 `open_player` 时，通知栏不该出现。 */
    external fun engineReady(): Boolean

    external fun stateCode(): Int

    external fun positionMs(): Long

    /** 当前曲目 id；`0` 表示没有播放项。 */
    external fun trackId(): Long

    /** 当前曲目标题；查不到时是 null（Kotlin 侧当空串用）。 */
    external fun trackTitle(): String?

    external fun trackArtist(): String?

    external fun trackDurationMs(): Long

    /** 播放失败的原因（给通知栏显示），没有则为 null。 */
    external fun errorText(): String?

    external fun play(): Boolean

    external fun pause(): Boolean

    external fun toggle(): Boolean

    external fun next(): Boolean

    external fun previous(): Boolean

    external fun stop(): Boolean

    external fun seekTo(positionMs: Long): Boolean
}
