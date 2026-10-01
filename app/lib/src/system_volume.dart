import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 系统媒体音量（音乐流），对应 `MainActivity` 里的 `com.qprs.musicplayer/playback` 通道。
///
/// 为什么用系统音量而不是 App 内部增益：侧键、系统音量条、其它 App 看到的都是同一个
/// 数值，不会出现「App 里拉到 100% 但手机只有 30%」的错乱；改音量时系统还会自己弹出
/// 音量条，用户一眼就有反馈。
class SystemVolume {
  const SystemVolume._();

  static const MethodChannel _channel = MethodChannel(
    'com.qprs.musicplayer/playback',
  );

  /// 读当前音量比例（0..1）；读不到返回 null（宿主机测试 / 通道缺失）。
  static Future<double?> current() => _invoke('getMusicVolume');

  /// 按格增减音量（正数变大、负数变小），返回调整后的比例（0..1）。
  static Future<double?> step(int steps) =>
      _invoke('adjustMusicVolume', {'steps': steps});

  /// 平台侧不该让“调音量”这种小事把界面搞崩：出错就返回 null，由调用方决定怎么提示。
  static Future<double?> _invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      return await _channel.invokeMethod<double>(method, arguments);
    } catch (e) {
      debugPrint('调整系统音量失败：$e');
      return null;
    }
  }
}
