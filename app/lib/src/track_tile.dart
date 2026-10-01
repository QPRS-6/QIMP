import 'package:flutter/material.dart';
import 'package:musicplayer/src/format.dart';
import 'package:musicplayer/src/rust/api/library.dart';

/// 曲目行（列表里的一首歌）。
///
/// 曲库页、播放列表页、队列页共用：三处的「正在播放」高亮、副标题拼法、
/// 时长位置必须长得一样，各写一份必然漂移。
class TrackTile extends StatelessWidget {
  const TrackTile({
    super.key,
    required this.track,
    required this.onTap,
    this.onLongPress,
    this.playing = false,
    this.paused = false,
    this.trailing,
  });

  final Track track;
  final VoidCallback onTap;

  /// 长按：曲库页用它弹出「添加到播放列表」。列表页里没有这个动作。
  final VoidCallback? onLongPress;

  /// 是否是当前播放项。
  final bool playing;

  /// 当前播放项是否处于暂停。
  final bool paused;

  /// 覆盖右侧内容（默认是时长）。播放列表的编辑模式用它换成「移出」按钮。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final subtitle = <String>[
      if (track.artist?.isNotEmpty ?? false) track.artist!,
      if (track.album?.isNotEmpty ?? false) track.album!,
      if (track.hasCover) '含封面',
    ].join(' · ');
    final accent = Theme.of(context).colorScheme.primary;
    return ListTile(
      dense: true,
      onTap: onTap,
      onLongPress: onLongPress,
      selected: playing,
      leading: Icon(
        playing
            ? (paused ? Icons.pause_circle_outline : Icons.equalizer)
            : Icons.music_note,
        color: playing ? accent : null,
      ),
      title: Text(
        displayTitle(track),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: playing ? TextStyle(color: accent) : null,
      ),
      subtitle: Text(
        subtitle.isEmpty ? track.path : subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: trailing ?? Text(formatDuration(track.durationMs)),
    );
  }
}
