import 'dart:async';

import 'package:flutter/foundation.dart';

/// 定时播放（睡眠定时）：到点把播放停掉。
///
/// 状态由曲库页持有，而不是放在全屏播放界面里：定时一旦开始，
/// 退出播放界面（回到列表、锁屏）都应该继续倒计时。
class SleepTimer extends ChangeNotifier {
  SleepTimer({required this.onFire, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  /// 到点时执行——当前实现是「暂停播放」而不是「停止」：
  /// 醒来后再点一下播放键就能接着听，播放位置还在。
  final VoidCallback onFire;

  /// 取当前时间。默认用系统时钟；测试里换成可手动推进的假时钟
  /// （`testWidgets` 的 FakeAsync 不会替换 `DateTime.now()`）。
  final DateTime Function() _now;

  /// 预设时长（分钟）。UI 直接拿它渲染菜单，避免两边各写一份。
  static const List<int> presets = [15, 30, 45, 60, 90];

  DateTime? _deadline;
  Duration? _remaining;
  Timer? _ticker;

  /// 剩余时间；`null` 表示当前没有在定时。
  Duration? get remaining => _remaining;

  bool get isActive => _remaining != null;

  /// 设定时长；传 `null` 表示取消定时。
  ///
  /// 倒计时按「截止时刻」算，而不是每秒自减：系统休眠、线程被卡住都不会让时间走偏。
  void set(Duration? duration) {
    _ticker?.cancel();
    _ticker = null;
    if (duration == null) {
      _deadline = null;
      _remaining = null;
      notifyListeners();
      return;
    }
    _deadline = _now().add(duration);
    _remaining = duration;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    notifyListeners();
  }

  void cancel() => set(null);

  void _tick() {
    final deadline = _deadline;
    if (deadline == null) return;
    final left = deadline.difference(_now());
    if (left <= Duration.zero) {
      // 先把自己收掉再触发动作：否则回调里看到的状态还是「定时中」，自相矛盾。
      set(null);
      onFire();
      return;
    }
    // 剩余时间向上取整到秒：刚设完 15 分钟就显示 14:59 会很别扭。
    _remaining = Duration(seconds: (left.inMilliseconds + 999) ~/ 1000);
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }
}
