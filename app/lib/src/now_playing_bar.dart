// Flutter 的 material 也导出了一个 `RepeatMode`（重复动画用）。
// 这里要用的是播放器的循环模式，所以把 Flutter 那个藏起来，避免歧义。
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:musicplayer/src/library_page.dart' show formatDuration;
import 'package:musicplayer/src/rust/api/library.dart';
import 'package:musicplayer/src/rust/api/player.dart';

/// 底部「正在播放」条：进度 + 播放控制。
///
/// 进度来自定时轮询的快照。拖动时用本地值渲染；松手后**不立刻**交还给轮询值，
/// 而是先把目标位置锁住——因为 `seek` 是异步的，紧接着读到的那次快照还是旧位置，
/// 直接跟随会造成「弹回旧位置 → 再跳到新位置」的抖动。
class NowPlayingBar extends StatefulWidget {
  const NowPlayingBar({
    super.key,
    required this.snapshot,
    required this.track,
    required this.onToggle,
    required this.onNext,
    required this.onPrevious,
    required this.onSeek,
    required this.onCycleRepeat,
  });

  final PlayerSnapshot? snapshot;

  /// 当前播放曲目（按 `snapshot.trackId` 从列表里找出来）；找不到时为 null。
  final Track? track;

  final VoidCallback onToggle;
  final VoidCallback onNext;
  final VoidCallback onPrevious;
  final ValueChanged<int> onSeek;
  final VoidCallback onCycleRepeat;

  @override
  State<NowPlayingBar> createState() => _NowPlayingBarState();
}

class _NowPlayingBarState extends State<NowPlayingBar> {
  /// 拖动中的位置（毫秒）；非 null 时不理会外部轮询值。
  double? _dragging;

  /// 已下发、但快照里还没反映出来的跳转目标（毫秒）。
  ///
  /// `seek` 只是把口令丢给播放线程，紧接着读到的那次快照仍然是**跳转前**的位置；
  /// 若不锁住目标，滑块会先弹回旧位置、等下一轮（最多 500ms）再跳到新位置。
  double? _pendingSeek;

  /// 锁住目标之后又轮询了几次：连续几次都追不上，说明这次跳转不会生效了。
  int _pendingPolls = 0;

  /// 快照位置与目标差多少就算「追上了」：精确跳转只能落在帧 / 包边界上。
  static const double _seekToleranceMs = 400;

  /// 兜底：连续这么多次轮询（约 3 秒）都没追上，就把控制权交还给轮询值。
  static const int _seekGiveUpPolls = 6;

  @override
  void didUpdateWidget(NowPlayingBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_pendingSeek == null) return;

    final snapshot = widget.snapshot;
    final previous = oldWidget.snapshot;
    // 换曲（自动续播 / 手动切歌）、停止、失败：这个目标已经没有意义了。
    if (snapshot == null ||
        snapshot.trackId != previous?.trackId ||
        snapshot.state == PlayerState.stopped ||
        snapshot.state == PlayerState.failed) {
      _releasePendingSeek();
      return;
    }
    if ((snapshot.positionMs - _pendingSeek!).abs() <= _seekToleranceMs) {
      _releasePendingSeek();
      return;
    }
    // 只有真正的新一轮轮询才计数（父级的其它重建会复用同一个快照对象）。
    if (!identical(snapshot, previous)) {
      _pendingPolls += 1;
      if (_pendingPolls >= _seekGiveUpPolls) {
        _releasePendingSeek();
      }
    }
  }

  /// 交还控制权：之后进度条重新跟随轮询值。
  void _releasePendingSeek() {
    _pendingSeek = null;
    _pendingPolls = 0;
  }

  /// 松手：先锁住目标，再通知外部跳转（顺序不能反，否则中间那次刷新会闪回旧位置）。
  void _commitSeek(double value) {
    setState(() {
      _dragging = null;
      _pendingSeek = value;
      _pendingPolls = 0;
    });
    widget.onSeek(value.round());
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    if (snapshot == null) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final track = widget.track;
    final total = track?.durationMs ?? 0;
    final upper = total > 0 ? total.toDouble() : double.maxFinite;
    // 拖动中跟手 → 刚跳转锁在目标 → 其余跟随轮询值。
    final shown = _dragging ?? _pendingSeek ?? snapshot.positionMs.toDouble();
    final position = shown.clamp(0.0, upper).toDouble();

    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Slider(
              // 时长未知（0）时不给拖动，避免滑到无意义的位置
              onChanged: total > 0
                  ? (value) => setState(() => _dragging = value)
                  : null,
              onChangeEnd: total > 0 ? _commitSeek : null,
              value: position,
              max: total > 0 ? total.toDouble() : 1,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 4, 8),
              child: Row(
                children: [
                  Expanded(
                    child: _TrackSummary(
                      track: track,
                      // 播放失败时把原因直接摆出来，比只改个按钮颜色有用得多
                      errorText: snapshot.error,
                      hint: _stateHint(snapshot.state),
                    ),
                  ),
                  IconButton(
                    tooltip: '上一首',
                    onPressed: widget.onPrevious,
                    icon: const Icon(Icons.skip_previous),
                  ),
                  IconButton.filled(
                    tooltip: snapshot.state == PlayerState.playing ? '暂停' : '播放',
                    onPressed: widget.onToggle,
                    icon: Icon(
                      snapshot.state == PlayerState.playing
                          ? Icons.pause
                          : Icons.play_arrow,
                    ),
                  ),
                  IconButton(
                    tooltip: '下一首',
                    onPressed: widget.onNext,
                    icon: const Icon(Icons.skip_next),
                  ),
                  IconButton(
                    tooltip: _repeatTooltip(snapshot.repeat),
                    onPressed: widget.onCycleRepeat,
                    // 循环开启时用主题色点亮：单曲循环只能用描边字形表达（见 _repeatIcon）。
                    color: _repeatColor(snapshot.repeat, theme.colorScheme),
                    icon: Icon(_repeatIcon(snapshot.repeat)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String? _stateHint(PlayerState state) {
    switch (state) {
      case PlayerState.stopped:
        return '已停止';
      case PlayerState.paused:
        return '已暂停';
      case PlayerState.playing:
      case PlayerState.failed:
        return null;
    }
  }

  /// 循环按钮的图标（关闭 / 列表循环 / 单曲循环）。
  ///
  /// 这里避开 `Icons.repeat_on` / `Icons.repeat_one_on` 这套 `_on` 实心变体：
  /// 随 Flutter 打包的 MaterialIcons 字体（`assets/flutter_assets/fonts/
  /// MaterialIcons-Regular.otf`）里**没有** `repeat_one_on`(U+E522) 的字形，
  /// 渲染出来是一个纯色方块，所以“开启”改用颜色表达（见 [_repeatColor]）。
  static IconData _repeatIcon(RepeatMode mode) {
    switch (mode) {
      case RepeatMode.off:
      case RepeatMode.all:
        return Icons.repeat;
      case RepeatMode.one:
        return Icons.repeat_one;
    }
  }

  /// 循环开启时用主题色点亮图标；关闭时用默认的前景色。
  static Color? _repeatColor(RepeatMode mode, ColorScheme scheme) =>
      mode == RepeatMode.off ? null : scheme.primary;

  static String _repeatTooltip(RepeatMode mode) {
    switch (mode) {
      case RepeatMode.off:
        return '循环：关闭（点击切换）';
      case RepeatMode.all:
        return '循环：列表循环（点击切换）';
      case RepeatMode.one:
        return '循环：单曲循环（点击切换）';
    }
  }
}

/// 标题 / 艺术家 / 时长，或者播放失败的原因。
class _TrackSummary extends StatelessWidget {
  const _TrackSummary({required this.track, this.errorText, this.hint});

  final Track? track;
  final String? errorText;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (errorText != null) {
      return Text(
        '播不了：$errorText',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      );
    }
    final track = this.track;
    if (track == null) {
      return Text('没有在播放', style: theme.textTheme.bodyMedium);
    }
    final subtitle = <String>[
      if (track.artist?.isNotEmpty ?? false) track.artist!,
      formatDuration(track.durationMs),
      ?hint,
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          track.title.isEmpty ? track.path.split('/').last : track.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium,
        ),
        Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}
