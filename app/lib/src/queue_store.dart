import 'package:flutter/foundation.dart';
import 'package:musicplayer/src/rust/api/library.dart';
import 'package:musicplayer/src/rust/api/player.dart';

/// 当前播放队列在 Dart 侧的一份镜像。
///
/// 引擎里当然也有队列，但它只活在播放线程里：快照只带 `index` / `queueLen` /
/// `trackId`，想在界面上「把队列列出来」就得拿全量条目。而队列**只由 App 自己设置**
/// （`setPlayQueue`，通知栏那几个按钮只在队列里前后走），引擎又随进程一起结束，
/// 所以这份镜像不会过期——不必为它去动 Rust 侧的线程模型。
class PlayQueueStore {
  PlayQueueStore();

  /// 队列条目（id + 路径）。`ValueNotifier` 让「队列」视图跟着刷新。
  final ValueNotifier<List<QueueEntry>> entries = ValueNotifier(
    const <QueueEntry>[],
  );

  /// 用一份新队列整体替换（`_playAt` 与播放列表页都会调）。
  void replace(List<QueueEntry> items) {
    entries.value = List<QueueEntry>.unmodifiable(items);
  }

  void dispose() => entries.dispose();
}

/// 把曲目列表变成队列条目。
List<QueueEntry> queueEntriesOf(List<Track> tracks) => <QueueEntry>[
  for (final track in tracks) QueueEntry(id: track.id, path: track.path),
];
