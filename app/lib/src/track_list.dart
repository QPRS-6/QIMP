import 'package:flutter/material.dart';
import 'package:musicplayer/src/rust/api/library.dart';
import 'package:musicplayer/src/rust/api/player.dart';
import 'package:musicplayer/src/track_tile.dart';

/// 曲目列表（主页那一份）。
///
/// 从 `library_page` 里搬出来单独成文件：多选模式那几行行为——点一下是勾选而不是
/// 播放、长按让位给复选框、左侧换成方框——值得单独钉住，而曲库页要跑起来得有
/// 真的 `.so`（开库 / 开播放器），在宿主机上摆不出来。
class TrackList extends StatelessWidget {
  const TrackList({
    super.key,
    required this.tracks,
    required this.emptyHint,
    required this.playingId,
    required this.onPlay,
    this.playingState,
    this.onLongPress,
    this.selecting = false,
    this.selectedIds = const <int>{},
    this.onToggleSelect,
  });

  final List<Track> tracks;
  final String emptyHint;

  /// 正在播放的曲目 id（`0` 表示当前没有播放项）。
  final int playingId;

  /// 播放状态，用来区分「在播」和「暂停」。
  final PlayerState? playingState;

  /// 点第 `index` 首（整个列表就是播放队列）。
  final ValueChanged<int> onPlay;

  /// 长按某一首（主页用来弹出动作表）。多选模式下长按没有意义，会被忽略。
  final ValueChanged<Track>? onLongPress;

  /// 多选模式：每一行前面换成复选框，点一下是勾选而不是播放。
  final bool selecting;

  /// 已勾选的曲目 id。
  final Set<int> selectedIds;

  /// 勾上 / 取消某一首。
  final ValueChanged<Track>? onToggleSelect;

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(emptyHint, textAlign: TextAlign.center),
        ),
      );
    }
    return ListView.builder(
      itemCount: tracks.length,
      itemBuilder: (context, index) {
        final track = tracks[index];
        final isPlaying = track.id == playingId;
        return TrackTile(
          track: track,
          playing: isPlaying,
          paused: isPlaying && playingState == PlayerState.paused,
          // 多选时左侧让给复选框——此刻它比“正在播”有用，反正当前项还有颜色标着。
          leading: selecting
              ? Checkbox(
                  value: selectedIds.contains(track.id),
                  onChanged: (_) => onToggleSelect?.call(track),
                )
              : null,
          // 点哪首就从哪首开始播：整个列表就是播放队列；多选时点一下是勾选。
          onTap: selecting
              ? () => onToggleSelect?.call(track)
              : () => onPlay(index),
          onLongPress: selecting || onLongPress == null
              ? null
              : () => onLongPress!(track),
        );
      },
    );
  }
}
