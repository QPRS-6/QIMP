package com.qprs.musicplayer

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 只做两件事：
 * - 把“是否已获得存储访问权 / 跳去申请”暴露给 Dart；
 * - 开始播放时把 [PlaybackService] 提到前台（后台播放 + 通知栏控制）。
 *
 * 这里刻意不引入 permission_handler 之类的插件：
 * 需求只有几个方法，手写 MethodChannel 依赖更少，也更好跟进 AGP 大版本升级。
 *
 * 注意：通知栏上的按钮**不经过这里**，它们直接走 JNI 打到 Rust（见 [PlaybackBridge]），
 * 这样即使用户把 App 从任务列表划掉、Flutter 引擎没了，控制也依然有效。
 */
class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasStorageAccess" -> result.success(hasStorageAccess())
                    "requestStorageAccess" -> {
                        requestStorageAccess()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PLAYBACK_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        startPlaybackService()
                        result.success(null)
                    }
                    // 音量：走**系统媒体音量**（音乐流），而不是 App 内部增益。
                    // 这样侧键、系统音量条、其它 App 看到的都是同一个数值，
                    // 不会出现“App 里拉满了但手机其实只有一点声”的错乱。
                    "getMusicVolume" -> result.success(musicVolume())
                    "adjustMusicVolume" -> {
                        val steps = call.argument<Int>("steps") ?: 0
                        result.success(adjustMusicVolume(steps))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** 当前音乐流音量（0..1）。 */
    private fun musicVolume(): Double {
        val audio = getSystemService(AudioManager::class.java) ?: return 0.0
        val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
        return audio.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() / max
    }

    /** 按格增减音乐流音量，返回调整后的比例（0..1）。 */
    private fun adjustMusicVolume(steps: Int): Double {
        val audio = getSystemService(AudioManager::class.java) ?: return 0.0
        if (steps != 0) {
            audio.adjustStreamVolume(
                AudioManager.STREAM_MUSIC,
                if (steps > 0) AudioManager.ADJUST_RAISE else AudioManager.ADJUST_LOWER,
                // 让系统把音量条显示出来：用户划一下就有反馈，不必我们再画一套。
                AudioManager.FLAG_SHOW_UI,
            )
        }
        return musicVolume()
    }

    /**
     * 启动播放前台服务。必须在 App 处于前台时调用（用户点了播放），
     * 否则 Android 12+ 会抛 ForegroundServiceStartNotAllowedException。
     * 服务只负责“别被杀 + 显示通知”，播放本身始终在 Rust 手里。
     */
    private fun startPlaybackService() {
        val intent = Intent(this, PlaybackService::class.java).setAction(PlaybackService.ACTION_START)
        ContextCompat.startForegroundService(this, intent)
    }

    /** Android 11+ 看“所有文件访问”特殊权限；更低版本看运行时读存储权限。 */
    private fun hasStorageAccess(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
        }

    private fun requestStorageAccess() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // 跳到本应用的“所有文件访问”设置页；用户返回后由 Dart 侧在 resume 时复查。
            val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                .setData(Uri.fromParts("package", packageName, null))
            startActivity(intent)
        } else {
            requestPermissions(arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE), REQUEST_CODE)
        }
    }

    private companion object {
        const val CHANNEL = "com.qprs.musicplayer/storage"
        const val PLAYBACK_CHANNEL = "com.qprs.musicplayer/playback"
        const val REQUEST_CODE = 1001
    }
}

