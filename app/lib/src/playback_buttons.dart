/// 播放控制的共享零件：随机 / 循环 / 播放暂停。
///
/// 单独抽出来是因为底部播放条与全屏播放界面都要放这套按钮，
/// 而这里有一条**不能各写一份**的约定：
///
/// `Icons.shuffle_on`(0xE5A2)、`Icons.repeat_on`(0xE520)、`Icons.repeat_one_on`(0xE522)
/// 这几个 `_on` 实心变体在随 Flutter 打包的 `MaterialIcons-Regular.otf` 里
/// **没有对应字形**，渲染出来是一个纯色方块（真机上踩过：单曲循环变成方块）。
/// 所以「开启」一律只用颜色（主题色）表达，图标永远用描边那一版。
library;

// Flutter 的 material 也导出了一个 `RepeatMode`（重复动画用）。
// 这里要用的是播放器的循环模式，所以把 Flutter 那个藏起来，避免歧义。
import 'package:flutter/material.dart' hide RepeatMode;

import 'package:musicplayer/src/rust/api/player.dart';

/// 随机播放按钮。图标只有一种画法，开启时用主题色点亮。
class ShuffleButton extends StatelessWidget {
  const ShuffleButton({
    super.key,
    required this.on,
    required this.onPressed,
    this.iconSize,
  });

  final bool on;
  final VoidCallback onPressed;
  final double? iconSize;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: shuffleTooltip(on),
      onPressed: onPressed,
      color: on ? Theme.of(context).colorScheme.primary : null,
      iconSize: iconSize,
      icon: const Icon(Icons.shuffle),
    );
  }
}

/// 循环模式按钮（关闭 → 列表循环 → 单曲循环）。
class RepeatButton extends StatelessWidget {
  const RepeatButton({
    super.key,
    required this.mode,
    required this.onPressed,
    this.shuffle = false,
    this.iconSize,
  });

  final RepeatMode mode;
  final VoidCallback onPressed;

  /// 随机播放是不是开着。
  ///
  /// 只影响提示文案：随机下「单曲循环」按列表循环走（见 `rust/audio` 的
  /// `PlayQueue::advance`），不说清楚用户会以为这个按钮坏了。
  final bool shuffle;

  final double? iconSize;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: repeatTooltip(mode, shuffle: shuffle),
      onPressed: onPressed,
      color: repeatColor(mode, Theme.of(context).colorScheme),
      iconSize: iconSize,
      icon: Icon(repeatIcon(mode)),
    );
  }
}

/// 播放 / 暂停（界面上那个大按钮）。
class PlayPauseButton extends StatelessWidget {
  const PlayPauseButton({
    super.key,
    required this.state,
    required this.onPressed,
    this.iconSize,
  });

  final PlayerState state;
  final VoidCallback onPressed;
  final double? iconSize;

  @override
  Widget build(BuildContext context) {
    final playing = state == PlayerState.playing;
    return IconButton.filled(
      tooltip: playing ? '暂停' : '播放',
      onPressed: onPressed,
      iconSize: iconSize,
      icon: Icon(playing ? Icons.pause : Icons.play_arrow),
    );
  }
}

/// 随机播放的提示：图标只有一种画法，所以当前是开还是关必须写清楚。
String shuffleTooltip(bool on) =>
    on ? '随机播放：开（点击关闭）' : '随机播放：关（点击开启）';

/// 循环按钮的图标（关闭 / 列表循环 / 单曲循环）。
IconData repeatIcon(RepeatMode mode) {
  switch (mode) {
    case RepeatMode.off:
    case RepeatMode.all:
      return Icons.repeat;
    case RepeatMode.one:
      return Icons.repeat_one;
  }
}

/// 循环开启时用主题色点亮图标；关闭时用默认的前景色。
Color? repeatColor(RepeatMode mode, ColorScheme scheme) =>
    mode == RepeatMode.off ? null : scheme.primary;

/// 循环按钮的提示。
///
/// [shuffle] 为真时「单曲循环」会多一句说明：那种组合下随机说了算，
/// 单曲循环按列表循环走——列表放完自动重开一轮（见 `rust/audio` 的
/// `PlayQueue::advance`）。不写清楚，用户会以为这个开关没生效。
String repeatTooltip(RepeatMode mode, {bool shuffle = false}) {
  switch (mode) {
    case RepeatMode.off:
      return '循环：关闭（点击切换）';
    case RepeatMode.all:
      return '循环：列表循环（点击切换）';
    case RepeatMode.one:
      return shuffle
          ? '循环：单曲循环（随机下按列表循环走，点击切换）'
          : '循环：单曲循环（点击切换）';
  }
}
