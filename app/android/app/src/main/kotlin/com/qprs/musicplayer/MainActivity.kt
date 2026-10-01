package com.qprs.musicplayer

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 只做一件事：把“是否已获得存储访问权 / 跳去申请”暴露给 Dart。
 *
 * 这里刻意不引入 permission_handler 之类的插件：
 * 需求只有两个方法，手写一个 MethodChannel 依赖更少，也更好跟进 AGP 大版本升级。
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
        const val REQUEST_CODE = 1001
    }
}

