// Flutter 的 material 也导出了一个 `RepeatMode`（重复动画用）。
// 这里要用的是播放器的循环模式，所以把 Flutter 那个藏起来，避免歧义。
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:musicplayer/src/library_page.dart' show formatDuration;
import 'package:musicplayer/src/rust/api/library.dart';
import 'package:musicplayer/src/rust/api/player.dart';

/// 底部「正在播放」条：进度 + 播放控制。
///
/// 进度来自定时轮询的快照；拖动时先用本地值渲染，松手才真正 seek——
/// 否则轮询结果会把滑块“拉回去”，手感很怪。
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

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    if (snapshot == null) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final track = widget.track;
    final total = track?.durationMs ?? 0;
    final position = (_dragging ?? snapshot.positionMs.toDouble())
        .clamp(0, total > 0 ? total.toDouble() : double.maxFinite)
        .toDouble();

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
              onChangeEnd: total > 0
                  ? (value) {
                      widget.onSeek(value.round());
                      setState(() => _dragging = null);
                    }
                  : null,
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

  static IconData _repeatIcon(RepeatMode mode) {
    switch (mode) {
      case RepeatMode.off:
        return Icons.repeat;
      case RepeatMode.all:
        return Icons.repeat_on;
      case RepeatMode.one:
        return Icons.repeat_one_on;
    }
  }

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
