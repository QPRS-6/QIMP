import 'package:musicplayer/src/rust/api/library.dart';
import 'package:musicplayer/src/rust/api/player.dart';

/// 「继续播放」的读写入口。
///
/// 与 `PlaylistApi` 是同一个套路：默认实现直接打 FFI（本地 SQLite，同步返回，
/// 快到不值得到处 await）；宿主机测试里没有 `.so`，所以留了一个可替换点。
class ProgressApi {
  const ProgressApi();

  /// 上次听到哪儿了（曲目 + 位置）；从没播放过任何东西时为 `null`。
  ResumePoint? lastPlayed() => resumePoint();

  /// 把当前进度写回曲库（同一首只有一行，覆盖即可）。
  void save(int trackId, int positionMs) =>
      savePlaybackPosition(trackId: trackId, positionMs: positionMs);

  /// 上次的**整份**播放队列；从没记过队列时为 `null`。
  ResumeQueue? lastQueue() => resumeQueue();

  /// 上次的**随机播放 / 循环模式**；从没记过时为 `null`。
  ///
  /// 与队列分开存：这两项是「怎么放」而不是「放什么」，用户在设置里改完就退出、
  /// 队列却没动过的情况很常见，各记各的最省事。
  PlaybackMode? lastMode() => playbackMode();

  /// 把当前的随机 / 循环设置写回曲库。
  void saveMode({required bool shuffle, required RepeatMode repeat}) =>
      savePlaybackMode(shuffle: shuffle, repeat: repeat);

  /// 退出时要落库的那一份设置；**还没有播放快照时返回 `null`**。
  ///
  /// 没有快照就说明引擎还没起来（首屏、初始化失败），这时候去写一个「默认值」，
  /// 只会把用户上次记下的那套盖掉——下次启动随机播放就莫名其妙关了。
  static ({bool shuffle, RepeatMode repeat})? modeToSave(
    PlayerSnapshot? snapshot,
  ) {
    if (snapshot == null) return null;
    return (shuffle: snapshot.shuffle, repeat: snapshot.repeat);
  }

  /// 把整份队列与当前项写回曲库（队列或当前项变了就该写一次）。
  void saveQueue(List<QueueEntry> entries, int index) => savePlayQueue(
    trackIds: [for (final entry in entries) entry.id],
    index: index,
  );

  /// 继续播放时的起始位置。
  ///
  /// 剩下的已经不足 [resumeTailMs] 时退回 0：只剩几秒钟的“接着放”没有意义，
  /// 不如从头完整放一遍。暂停在最后一秒然后退出应用是很常见的事，这一步就是为它准备的。
  static int startMsFor({required int positionMs, required int durationMs}) {
    if (positionMs <= 0) return 0;
    // 时长未知（解析失败 / 流式文件）：只能信进度本身。
    if (durationMs <= 0) return positionMs;
    if (durationMs - positionMs < resumeTailMs) return 0;
    return positionMs;
  }

  /// 距离结尾不足这么多毫秒时，认为“这一首已经放完了”。
  static const int resumeTailMs = 5000;

  /// 把落库的队列整理成能直接装进引擎的方案。
  ///
  /// 两件事：
  /// - 文件已经不在了的条目（删了、还没重扫）**剔掉**：留着只会在播到它时报错；
  /// - 「上次那一首」按整理后的下标重新定位；它正好被删了就退回队列开头、
  ///   进度也清零（把别人的进度安在新的一首上会很莫名其妙）。
  ///
  /// 返回 `null` 表示整队都不剩什么了，没什么可接着放的。
  static ResumePlan? plan({
    required ResumeQueue saved,
    required bool Function(String path) exists,
  }) {
    final entries = <QueueEntry>[];
    var index = 0;
    var found = false;
    for (var i = 0; i < saved.entries.length; i++) {
      final entry = saved.entries[i];
      if (!exists(entry.path)) continue;
      if (i == saved.index) {
        index = entries.length;
        found = true;
      }
      entries.add(QueueEntry(id: entry.id, path: entry.path));
    }
    if (entries.isEmpty) return null;
    return ResumePlan(
      entries: entries,
      index: index,
      positionMs: found ? saved.positionMs : 0,
    );
  }
}

/// 接着上次的听：整理好的队列、当前项、起始进度。
class ResumePlan {
  const ResumePlan({
    required this.entries,
    required this.index,
    required this.positionMs,
  });

  final List<QueueEntry> entries;
  final int index;
  final int positionMs;
}
