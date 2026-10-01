package com.qprs.musicplayer

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.database.ContentObserver
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * 两条「声音不该再响」的自动暂停规则：
 *
 * - **音量归零**：媒体音量被拉到 0 了（封面下滑到底、侧键按到底、别的 App 调的），
 *   再放着只是白耗电、还一直占着音频焦点，直接暂停；
 * - **蓝牙断开**：耳机 / 音箱一断，声音会突然从外放响起来——这是最招人嫌的体验。
 *   官方给播放器准备的信号是 `ACTION_AUDIO_BECOMING_NOISY`，收到就该暂停。
 *
 * 为什么放在平台侧而不是 Dart：这两件事都不该依赖 Flutter 引擎还活着。用户把 App
 * 从任务列表划掉之后 Dart 早没了，播放与前台服务却还在跑；何况音量与音频路由的变化
 * 只有系统知道，Dart 那侧要么轮询、要么再加一条事件通道，都绕远了。
 *
 * 「停止」＝**暂停**，不是清空播放项：跟定时播放同一个道理，随手点一下就能接着听。
 * 真停下来意味着通知没了、播放项也没了，用户只是拔一下耳机就要重新找歌，不划算。
 */
internal class PlaybackAutoStop(
    private val context: Context,
    /** 现在是不是真的在出声（暂停 / 停止 / 引擎没起来都不算）。 */
    private val isPlaying: () -> Boolean,
    /** 暂停播放。重复调用是安全的。 */
    private val pause: () -> Unit,
) {
    private val audio = context.getSystemService(AudioManager::class.java)
    private val handler = Handler(Looper.getMainLooper())

    /** 是否已经注册；[start] / [stop] 都允许重复调用。 */
    private var running = false

    /**
     * 音乐流音量变化。
     *
     * 音量存在 `Settings.System` 里，系统改音量就是写这张表，所以一个观察者就覆盖了
     * 所有来源：封面手势、侧键、系统音量条、别的 App。为什么不监听
     * `AudioManager.VOLUME_CHANGED_ACTION`：那个常量在 Android 13 之前是隐藏 API，
     * 各 ROM 发得也不一致；观察设置表是所有版本都成立的公开做法。
     *
     * 代价是**任何**设置变化都会回调一次（亮度、铃声……），所以这里只做一次读音量
     * 的廉价判断，其余一律不管。
     */
    private val volumeObserver = object : ContentObserver(handler) {
        override fun onChange(selfChange: Boolean, uri: Uri?) {
            if (shouldPauseOnVolume(musicVolume())) stopIfPlaying("音量已到 0")
        }
    }

    /**
     * 音频输出设备的增删。这条只管蓝牙：走掉的里面有蓝牙输出、而且现在一个蓝牙输出
     * 都不剩了，才认为「蓝牙断了」。有线耳机拔插、投屏切换不归它管（耳机拔出由下面
     * 那条广播兜住）。
     */
    private val deviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
            val remaining = audio?.getDevices(AudioManager.GET_DEVICES_OUTPUTS).orEmpty()
            val lost = bluetoothOutputGone(
                removedTypes = removedDevices.map { it.type },
                remainingTypes = remaining.map { it.type },
            )
            if (lost) stopIfPlaying("蓝牙输出已断开")
        }
    }

    /**
     * 「音频即将改成外放」。蓝牙断开、有线耳机拔出，系统都会发这条广播——这正是官方
     * 给播放器准备的信号（`AudioManager.ACTION_AUDIO_BECOMING_NOISY` 的说明就写着
     * 「收到后应当暂停」）。它和上面那个设备回调是互补的：回调给的是「谁走了」这种
     * 精确信息，广播则是各 ROM 都认得的兜底信号，所以两边都留着。
     */
    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) =
            stopIfPlaying("音频输出已改为外放")
    }

    fun start() {
        if (running) return
        running = true
        // 只观察「设置变了」这件事本身；具体是哪一项、变成多少，回调里再查。
        context.contentResolver.registerContentObserver(
            Settings.System.CONTENT_URI,
            true,
            volumeObserver,
        )
        audio?.registerAudioDeviceCallback(deviceCallback, handler)
        ContextCompat.registerReceiver(
            context,
            noisyReceiver,
            IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
    }

    fun stop() {
        if (!running) return
        running = false
        context.contentResolver.unregisterContentObserver(volumeObserver)
        audio?.unregisterAudioDeviceCallback(deviceCallback)
        runCatching { context.unregisterReceiver(noisyReceiver) }
    }

    /**
     * 真在出声才动手：暂停状态下再「暂停」一次没有意义，也别去打扰引擎。
     *
     * 留一条日志：这两件事都是后台悄悄发生的，用户只会发现「歌停了」，说不清是谁停的；
     * 出了疑问 `adb logcat -s PlaybackAutoStop` 就能看清是哪条规则动的手。
     */
    private fun stopIfPlaying(reason: String) {
        if (!isPlaying()) return
        Log.i(TAG, "自动暂停：$reason")
        pause()
    }

    /** 音乐流音量（档位）。读不到时给 [UNKNOWN_VOLUME]，**绝不能**落回 0（那等于「静音」）。 */
    private fun musicVolume(): Int =
        audio?.getStreamVolume(AudioManager.STREAM_MUSIC) ?: UNKNOWN_VOLUME

    private companion object {
        const val TAG = "PlaybackAutoStop"
    }
}

/** 读不到音量时的哨兵值：必须不是 0，否则「不知道」会被当成「静音」而乱停。 */
private const val UNKNOWN_VOLUME = -1

/**
 * 音量到 0（静音）就该暂停。
 *
 * 抽成不碰 Android 运行时的纯函数，是为了能在宿主机上直接测（`PlaybackAutoStopTest`），
 * 否则这几条规则只能靠插拔真耳机去验。
 *
 * 「读不到音量」用的是负数哨兵，所以这一条顺带保证了**不知道 ≠ 静音**：
 * 万一哪天有人把哨兵改成 0，测试会立刻红。
 */
fun shouldPauseOnVolume(volume: Int): Boolean = volume == 0

/**
 * 蓝牙音频断了没：被移除的设备里有蓝牙输出、而且现在一个蓝牙输出都不剩。
 *
 * 判据用「还剩不剩」而不是「走的是不是当前出声的那台」：手机同时接着耳机与音箱时，
 * 只走掉一台不该停（声音还有地方去）。
 */
fun bluetoothOutputGone(removedTypes: List<Int>, remainingTypes: List<Int>): Boolean =
    removedTypes.any(::isBluetoothOutput) && remainingTypes.none(::isBluetoothOutput)

/**
 * 这个输出设备类型算不算「蓝牙音频输出」。
 *
 * 除了经典的 A2DP（音乐）与 SCO（通话），还有 LE Audio 那几个（API 31+ 才有）。
 * 后面这些常量在编译期就内联成了数字，低版本上不会出现这种类型，留着无害。
 */
fun isBluetoothOutput(type: Int): Boolean =
    type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
        type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
        type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
        type == AudioDeviceInfo.TYPE_BLE_SPEAKER ||
        type == AudioDeviceInfo.TYPE_BLE_BROADCAST
