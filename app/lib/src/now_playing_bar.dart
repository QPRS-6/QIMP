// Flutter 的 material 也导出了一个 `RepeatMode`（重复动画用）。
// 这里要用的是播放器的循环模式，所以把 Flutter 那个藏起来，避免歧义。
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:musicplayer/src/format.dart';
import 'package:musicplayer/src/playback_buttons.dart';
import 'package:musicplayer/src/rust/api/library.dart';
import 'package:musicplayer/src/rust/api/player.dart';
import 'package:musicplayer/src/seek_slider.dart';

/// 底部「正在播放」条：进度 + 播放控制。
///
/// 点标题区域会打开全屏播放界面；进度条与各个按钮的时序细节分别收在
/// [SeekSlider] 与 [playback_buttons] 里，两处界面共用同一套行为。
class NowPlayingBar extends StatelessWidget {
  const NowPlayingBar({
    super.key,
    required this.snapshot,
    required this.track,
    required this.onToggle,
    required this.onNext,
    required this.onPrevious,
    required this.onSeek,
    required this.onCycleRepeat,
    required this.onToggleShuffle,
    required this.onOpenPlayer,
    this.bottomSafeArea = true,
  });

  final PlayerSnapshot? snapshot;

  /// 当前播放曲目（按 `snapshot.trackId` 从列表里找出来）；找不到时为 null。
  final Track? track;

  final VoidCallback onToggle;
  final VoidCallback onNext;
  final VoidCallback onPrevious;
  final ValueChanged<int> onSeek;
  final VoidCallback onCycleRepeat;

  /// 随机播放开关。它与循环模式互不干扰：随机决定「下一首是谁」，
  /// 循环决定「一轮放完怎么办」。
  final VoidCallback onToggleShuffle;

  /// 点标题区域打开全屏播放界面（没有曲目时不可点）。
  final VoidCallback onOpenPlayer;

  /// 是否自己吃掉底部系统栏的安全区（默认吃）。
  ///
  /// 主页把「曲库工具条」压在播放条下面，那种布局下安全区该由那条工具条负责；
  /// 两边各加一次的话，中间会多出一条谁也说不清干什么的缝（见 `library_page`）。
  final bool bottomSafeArea;

  @override
  Widget build(BuildContext context) {
    final snapshot = this.snapshot;
    if (snapshot == null) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final track = this.track;

    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        bottom: bottomSafeArea,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 进度条自己管「拖动 / 跳转后锁住目标」的时序（见 SeekSlider）。
            SeekSlider(
              snapshot: snapshot,
              totalMs: track?.durationMs ?? 0,
              onSeek: onSeek,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 4, 8),
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      // 点标题进全屏播放界面；没有曲目时不给点（进去也没东西可看）。
                      onTap: track == null ? null : onOpenPlayer,
                      child: _TrackSummary(
                        track: track,
                        // 曲库里没记时长时用解码器算出来的那份（见 SeekSlider 的说明）。
                        durationMs: trackTotalMs(
                          fromLibrary: track?.durationMs ?? 0,
                          fromEngine: snapshot.durationMs,
                        ),
                        // 播放失败时把原因直接摆出来，比只改个按钮颜色有用得多
                        errorText: snapshot.error,
                        hint: _stateHint(snapshot.state),
                      ),
                    ),
                  ),
                  ShuffleButton(
                    on: snapshot.shuffle,
                    onPressed: onToggleShuffle,
                  ),
                  IconButton(
                    tooltip: '上一首',
                    onPressed: onPrevious,
                    icon: const Icon(Icons.skip_previous),
                  ),
                  PlayPauseButton(state: snapshot.state, onPressed: onToggle),
                  IconButton(
                    tooltip: '下一首',
                    onPressed: onNext,
                    icon: const Icon(Icons.skip_next),
                  ),
                  RepeatButton(
                    mode: snapshot.repeat,
                    shuffle: snapshot.shuffle,
                    onPressed: onCycleRepeat,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 循环 / 随机的图标与提示都搬到了 [playback_buttons]：
  /// 底部播放条与全屏播放界面必须用同一套（尤其是那条「`*_on` 字形不存在」的坑，
  /// 不能各写一份）。
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
}

/// 标题 / 艺术家 / 时长，或者播放失败的原因。
class _TrackSummary extends StatelessWidget {
  const _TrackSummary({
    required this.track,
    required this.durationMs,
    this.errorText,
    this.hint,
  });

  final Track? track;

  /// 这首歌有多长（曲库那份优先，曲库不知道时用解码器算出来的）。
  final int durationMs;

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
      formatDuration(durationMs),
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
