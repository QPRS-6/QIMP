import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:musicplayer/src/format.dart';
import 'package:musicplayer/src/rust/api/library.dart';
import 'package:musicplayer/src/rust/api/player.dart';

/// 当前播放队列。
///
/// 队列条目只有 id + 路径（播放引擎要的东西），标题 / 时长得回曲库查，
/// 所以这里要一个 `trackById`。查不到就退回文件名，不显示空行。
class QueueView extends StatelessWidget {
  const QueueView({
    super.key,
    required this.queue,
    required this.player,
    required this.trackById,
    required this.onJump,
  });

  /// 队列镜像（`PlayQueueStore.entries`）。
  final ValueListenable<List<QueueEntry>> queue;

  final ValueListenable<PlayerSnapshot?> player;

  /// 按 id 回查曲目（曲库页的缓存在这里复用）。
  final Track? Function(int id) trackById;

  /// 跳到队列里的第 `index` 首。
  final ValueChanged<int> onJump;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<QueueEntry>>(
      valueListenable: queue,
      builder: (context, entries, _) {
        if (entries.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                '还没有播放队列。\n在「主页」或某个播放列表里点一首歌就有了。',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return ValueListenableBuilder<PlayerSnapshot?>(
          valueListenable: player,
          builder: (context, snapshot, _) => _buildList(context, entries, snapshot),
        );
      },
    );
  }

  Widget _buildList(
    BuildContext context,
    List<QueueEntry> entries,
    PlayerSnapshot? snapshot,
  ) {
    final playingId = snapshot?.trackId ?? 0;
    final currentIndex = snapshot?.index ?? 0;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '队列 ${entries.length} 首 · 正在放第 ${currentIndex + 1} 首',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              // 随机播放时列表顺序不是播放顺序，说清楚比让人自己猜好。
              if (snapshot?.shuffle ?? false)
                Text('随机播放中', style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[index];
              final track = trackById(entry.id);
              final isPlaying = entry.id == playingId;
              return ListTile(
                dense: true,
                selected: isPlaying,
                leading: Icon(
                  isPlaying
                      ? (snapshot?.state == PlayerState.paused
                            ? Icons.pause_circle_outline
                            : Icons.equalizer)
                      : Icons.music_note,
                  color: isPlaying
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                title: Text(
                  track == null ? _fileNameOf(entry.path) : displayTitle(track),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  track == null ? entry.path : formatDuration(track.durationMs),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => onJump(index),
              );
            },
          ),
        ),
      ],
    );
  }

  static String _fileNameOf(String path) => path.split('/').last;
}
