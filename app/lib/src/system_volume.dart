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

  /// 把音量直接设成 [ratio]（0..1），返回平台落定后的比例（0..1）。
  ///
  /// 用「设成多少」而不是「加几格」：封面上的音量是跟手线性的，
  /// 滑动距离换算出来的就是一个绝对比例，取整交给平台侧按系统档位去做。
  static Future<double?> setRatio(double ratio) =>
      _invoke('setMusicVolume', {'ratio': ratio});

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
