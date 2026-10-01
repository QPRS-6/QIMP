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

PlayerSnapshot fakeSnapshot({
  int trackId = 7,
  int positionMs = 0,
  PlayerState state = PlayerState.playing,
  RepeatMode repeat = RepeatMode.off,
  bool shuffle = false,
}) => PlayerSnapshot(
  state: state,
  positionMs: positionMs,
  index: 0,
  queueLen: 1,
  trackId: trackId,
  repeat: repeat,
  shuffle: shuffle,
);
