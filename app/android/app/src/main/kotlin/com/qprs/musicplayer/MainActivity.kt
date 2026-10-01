package com.qprs.musicplayer

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.OpenableColumns
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.IOException
import kotlin.math.roundToInt

/**
 * 只做三件事：
 * - 把“是否已获得存储访问权 / 跳去申请”暴露给 Dart；
 * - 用系统文件对话框选 / 存播放列表文件（xspf / m3u8）；
 * - 开始播放时把 [PlaybackService] 提到前台（后台播放 + 通知栏控制）。
 *
 * 这里刻意不引入 permission_handler / file_picker 之类的插件：
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
                    "setMusicVolume" -> {
                        val ratio = call.argument<Double>("ratio") ?: 0.0
                        result.success(setMusicVolume(ratio))
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FILES_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pick" -> pickPlaylistFile(result)
                    "save" -> {
                        val name = call.argument<String>("name") ?: "playlist.m3u8"
                        val bytes = call.argument<ByteArray>("bytes") ?: ByteArray(0)
                        savePlaylistFile(name, bytes, result)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // -----------------------------------------------------------------------
    // 播放列表文件：选 / 存
    //
    // 为什么走 SAF 而不是直接读写路径：用户挑的文件在别的应用 / SD 卡上，
    // 系统只给一个 `content://`，真实路径既拿不到也不该拿。所以这里只负责
    // 把字节读出来交给 Dart（再进 Rust 解析）——解析规则全在 core 里，
    // 宿主机上就能测（见 `musicplayer_core::playlist_file`）。
    // -----------------------------------------------------------------------

    /** 让用户挑一个 xspf / m3u8 文件；取消时回 `null`。 */
    private fun pickPlaylistFile(result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("busy", "已经有一个文件选择框开着", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            // 刻意不按 MIME 过滤：各家文件管理器给 .m3u8 / .xspf 报的类型五花八门
            // （text/plain、application/octet-stream、audio/x-mpegurl…），
            // 一过滤反而挑不到文件。格式交给 Rust 按内容判断。
            type = "*/*"
        }
        pendingPick = result
        startActivityForResult(intent, REQUEST_PICK_PLAYLIST)
    }

    /** 让用户挑个位置保存；取消时回 `null`，成功回落定后的文件名。 */
    private fun savePlaylistFile(name: String, bytes: ByteArray, result: MethodChannel.Result) {
        if (pendingSave != null) {
            result.error("busy", "已经有一个保存框开着", null)
            return
        }
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mimeOf(name)
            // 带上扩展名：系统会拿它当默认文件名，用户改不改都行。
            putExtra(Intent.EXTRA_TITLE, name)
        }
        pendingSave = PendingSave(result, name, bytes)
        startActivityForResult(intent, REQUEST_SAVE_PLAYLIST)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        // 先交给 Flutter（别的插件可能也在这个回调上），再处理我们自己的两个。
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            REQUEST_PICK_PLAYLIST -> finishPick(resultCode, data)
            REQUEST_SAVE_PLAYLIST -> finishSave(resultCode, data)
        }
    }

    private fun finishPick(resultCode: Int, data: Intent?) {
        val result = pendingPick
        pendingPick = null
        if (result == null) return

        val uri = if (resultCode == RESULT_OK) data?.data else null
        if (uri == null) {
            result.success(null) // 用户取消
            return
        }
        try {
            val bytes = readAll(uri)
            if (bytes.isEmpty()) {
                result.success(null)
                return
            }
            result.success(mapOf("name" to (displayName(uri) ?: "playlist"), "bytes" to bytes))
        } catch (e: Exception) {
            result.error("pick_failed", e.message ?: "读不出这个文件", null)
        }
    }

    private fun finishSave(resultCode: Int, data: Intent?) {
        val pending = pendingSave
        pendingSave = null
        if (pending == null) return

        val uri = if (resultCode == RESULT_OK) data?.data else null
        if (uri == null) {
            pending.result.success(null) // 用户取消
            return
        }
        try {
            // "wt" = 覆盖写：用户挑了个已存在的文件时，期望的是替换而不是接在后面。
            contentResolver.openOutputStream(uri, "wt")?.use { it.write(pending.bytes) }
                ?: throw IOException("打不开这个位置")
            pending.result.success(displayName(uri) ?: pending.name)
        } catch (e: Exception) {
            pending.result.error("save_failed", e.message ?: "写不进去", null)
        }
    }

    /** 读 `content://` 的全部内容；超过上限直接报错，免得用户挑错文件把内存吃爆。 */
    private fun readAll(uri: Uri): ByteArray {
        val stream = contentResolver.openInputStream(uri) ?: throw IOException("打不开这个文件")
        stream.use { input ->
            val out = ByteArrayOutputStream()
            val buffer = ByteArray(16 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read <= 0) break
                out.write(buffer, 0, read)
                if (out.size() > MAX_PLAYLIST_BYTES) {
                    throw IOException("文件太大，不像是播放列表")
                }
            }
            return out.toByteArray()
        }
    }

    /** 拿到文件在界面上显示的名字（`夜跑.m3u8`）。 */
    private fun displayName(uri: Uri): String? {
        val cursor = contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null,
        ) ?: return null
        cursor.use {
            if (!it.moveToFirst()) return null
            val index = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            return if (index >= 0) it.getString(index) else null
        }
    }

    /** 保存对话框用的 MIME：认不出来时给个通用值，文件名里的扩展名照样保留。 */
    private fun mimeOf(name: String): String {
        val extension = name.substringAfterLast('.', "").lowercase()
        return when (extension) {
            "m3u8", "m3u" -> "audio/x-mpegurl"
            "xspf" -> "application/xspf+xml"
            else -> "application/octet-stream"
        }
    }

    /** 当前音乐流音量（0..1）。 */
    private fun musicVolume(): Double {
        val audio = getSystemService(AudioManager::class.java) ?: return 0.0
        val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
        return audio.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() / max
    }

    /**
     * 把音乐流音量设成 [ratio]（0..1），返回落定后的比例（0..1）。
     *
     * 封面上的音量是**跟手线性**的：上层把「手指滑了多远」直接换算成比例，
     * 这里再按系统的档位数取整。设完重新读一次返回，界面显示的就是真实值
     * （比如系统只有 15 档，请求 0.42 实际会落在最接近的那一档上）。
     */
    private fun setMusicVolume(ratio: Double): Double {
        val audio = getSystemService(AudioManager::class.java) ?: return 0.0
        val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
        val level = (ratio.coerceIn(0.0, 1.0) * max).roundToInt().coerceIn(0, max)
        audio.setStreamVolume(
            AudioManager.STREAM_MUSIC,
            level,
            // 让系统把音量条显示出来：用户划一下就有反馈，不必我们再画一套。
            AudioManager.FLAG_SHOW_UI,
        )
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
        const val FILES_CHANNEL = "com.qprs.musicplayer/files"
        const val REQUEST_CODE = 1001
        const val REQUEST_PICK_PLAYLIST = 1002
        const val REQUEST_SAVE_PLAYLIST = 1003

        /** 播放列表文件的读取上限。真列表只有几十 KB，超了基本就是挑错文件了。 */
        const val MAX_PLAYLIST_BYTES = 4 * 1024 * 1024
    }

    /** 正在等用户挑文件的那一次 `pick`。 */
    private var pendingPick: MethodChannel.Result? = null

    /** 正在等用户挑保存位置的那一次 `save`。 */
    private var pendingSave: PendingSave? = null

    /** 待落盘的字节：位置要等用户选了才知道，所以先把内容存这儿。 */
    private class PendingSave(
        val result: MethodChannel.Result,
        val name: String,
        val bytes: ByteArray,
    )
}

