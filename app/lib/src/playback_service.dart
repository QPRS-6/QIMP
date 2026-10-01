import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 播放前台服务桥，对应 `MainActivity` 里的 `com.qprs.musicplayer/playback` 通道。
///
/// 平台侧（`PlaybackService.kt`）负责“别被系统回收 + 通知栏 / 锁屏控制”，
/// 播放本身始终在 Rust 手里；通知上的按钮走 JNI 直达 Rust，不经过 Dart。
/// 所以这里只有一件事要做：**开始播放时把服务提起来**（Android 12+ 要求
/// 在前台调用 `startForegroundService`，用户点播放时正好满足）。
class PlaybackService {
  const PlaybackService._();

  static const MethodChannel _channel = MethodChannel(
    'com.qprs.musicplayer/playback',
  );

  /// 确保服务已启动。重复调用是安全的（平台侧只是再投递一次“启动”意图）。
  ///
  /// 失败只记日志、不打断播放：宿主机测试没有这个通道，用户拒绝后台运行也不该让
  /// 播放变成“点了没反应”。
  static Future<void> start() async {
    try {
      await _channel.invokeMethod<void>('start');
    } catch (e) {
      debugPrint('启动播放服务失败（不影响前台播放）：$e');
    }
  }
}
