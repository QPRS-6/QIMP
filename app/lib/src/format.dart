/// 显示层的格式化函数。
///
/// 单独放一个文件：曲目行（`track_tile`）、底部播放条、全屏播放界面、
/// 各页面头部都要用，留在 `library_page` 里会让每个使用者都反向依赖那个页面。
library;

import 'package:musicplayer/src/rust/api/library.dart';

/// 曲目的显示名：优先标题，空标题回退到文件名（与 core 的 `Track::display_title` 一致）。
String displayTitle(Track track) =>
    track.title.trim().isEmpty ? track.path.split('/').last : track.title;

/// 毫秒 → `m:ss`。与核心的约定一致：`0` 表示时长未知，显示 `--:--`。
String formatDuration(int ms) {
  if (ms <= 0) return '--:--';
  final totalSeconds = (ms / 1000).round();
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

/// 毫秒 → `h:mm:ss`。用于“总时长”这种必然超过一小时的数字。
String formatDurationLong(int ms) {
  if (ms <= 0) return '0:00';
  final totalSeconds = (ms / 1000).round();
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  final mm = minutes.toString().padLeft(2, '0');
  final ss = seconds.toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$mm:$ss' : '$minutes:$ss';
}

/// 字节 → 人类可读（保留一位小数）。
String formatSize(int bytes) {
  const units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return unit == 0
      ? '${value.toInt()} ${units[unit]}'
      : '${value.toStringAsFixed(1)} ${units[unit]}';
}
