// 测试夹具：假曲目与假快照。
//
// 播放条、全屏播放界面、定时播放的用例都要用它们，所以单独放一份：
// 三份各自复制的话，字段一多就必然漂移（而且漂移时测试照样是绿的）。
import 'package:musicplayer/src/rust/api/library.dart';
import 'package:musicplayer/src/rust/api/player.dart';

/// 假曲目的默认时长（毫秒）：进度条按它算总长。
const int fakeDurationMs = 200000;

Track fakeTrack({
  int id = 7,
  int durationMs = fakeDurationMs,
  String title = '测试曲目',
  String? artist = '某位歌手',
  String? album = '某张专辑',
}) => Track(
  id: id,
  path: '/storage/emulated/0/Music/test.mp3',
  title: title,
  artist: artist,
  album: album,
  durationMs: durationMs,
  sizeBytes: 1024,
  modifiedAt: 0,
  hasCover: false,
  addedAt: 0,
);

/// 假歌词：`(起始毫秒, 文本)` 列表 → 一份**带时间轴**的歌词。
///
/// 纯文本歌词（内嵌歌词的常见形态）用 [fakePlainLyrics]。
Lyrics fakeLyrics(List<(int, String)> lines) => Lyrics(
  lines: [
    for (final (timeMs, text) in lines) LyricLine(timeMs: timeMs, text: text),
  ],
  offsetMs: 0,
  synced: true,
);

/// 假歌词：没有时间轴的那一种（整段文字）。
Lyrics fakePlainLyrics(List<String> lines) => Lyrics(
  lines: [for (final text in lines) LyricLine(timeMs: 0, text: text)],
  offsetMs: 0,
  synced: false,
);

PlayerSnapshot fakeSnapshot({
  int trackId = 7,
  int positionMs = 0,
  int durationMs = 0,
  PlayerState state = PlayerState.playing,
  RepeatMode repeat = RepeatMode.off,
  bool shuffle = false,
}) => PlayerSnapshot(
  state: state,
  positionMs: positionMs,
  index: 0,
  queueLen: 1,
  trackId: trackId,
  // 默认 0＝解码器也不知道时长：绝大多数用例关心的是「曲库里那份」，
  // 只有专门测“兜底”的用例才需要填它。
  durationMs: durationMs,
  repeat: repeat,
  shuffle: shuffle,
);
