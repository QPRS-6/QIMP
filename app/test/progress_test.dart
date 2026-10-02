// 「继续播放」的起点规则，以及「整队接着放」的整理规则。
//
// 这两套规则决定“启动时点一下播放该从哪儿响、队列里还有哪些歌”，
// 而它要重启应用才看得到，所以抽成纯函数在这里钉住：
// 差一点点就是「又从开头听一遍」或者「一按就结束」；
// 后者更糟——只还原一首歌的话，重启后「下一曲」就是个死键。
import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/src/progress_api.dart';
import 'package:musicplayer/src/rust/api/library.dart' as rust;
import 'package:musicplayer/src/rust/api/player.dart' show RepeatMode;

import 'fixtures.dart';

void main() {
  int start({required int positionMs, required int durationMs}) =>
      ProgressApi.startMsFor(positionMs: positionMs, durationMs: durationMs);

  test('听到一半：从那儿接着放', () {
    expect(start(positionMs: 42000, durationMs: 200000), 42000);
  });

  test('没听过 / 位置是负数：从头放', () {
    expect(start(positionMs: 0, durationMs: 200000), 0);
    expect(start(positionMs: -1, durationMs: 200000), 0);
  });

  test('快放完了就从头放：只剩几秒的“继续”没有意义', () {
    // 距结尾不足 5 秒 —— 多半是听着听着暂停在末尾，当成已经放完。
    expect(start(positionMs: 196000, durationMs: 200000), 0);
    expect(start(positionMs: 200000, durationMs: 200000), 0);
    // 时长缩水（重新转码过）也不该算出超过总长的位置。
    expect(start(positionMs: 300000, durationMs: 200000), 0);
    // 刚好还剩 5 秒：接着放。
    expect(start(positionMs: 195000, durationMs: 200000), 195000);
  });

  test('时长未知：只能信进度本身', () {
    expect(start(positionMs: 42000, durationMs: 0), 42000);
  });

  test('退出时记下的随机 / 循环：只认播放快照，没有快照就不许写', () {
    // 引擎还没起来（首屏、初始化失败）时写一个「默认值」进去，会把用户上次记下的
    // 那套盖掉——下次启动随机播放就莫名其妙被关了，所以这种情况宁可什么都不写。
    expect(ProgressApi.modeToSave(null), isNull);

    final saved = ProgressApi.modeToSave(
      fakeSnapshot(shuffle: true, repeat: RepeatMode.one),
    )!;
    expect(saved.shuffle, isTrue);
    expect(saved.repeat, RepeatMode.one);

    final off = ProgressApi.modeToSave(fakeSnapshot())!;
    expect(off.shuffle, isFalse, reason: '默认是关的，也要如实记下来');
    expect(off.repeat, RepeatMode.off);
  });

  /// 假队列快照：ids 逐个对应 `/m/<id>.mp3`。
  rust.ResumeQueue saved({
    required List<int> ids,
    int index = 0,
    int positionMs = 0,
  }) => rust.ResumeQueue(
    entries: [
      for (final id in ids) rust.QueueTrack(id: id, path: '/m/$id.mp3'),
    ],
    index: index,
    positionMs: positionMs,
  );

  ResumePlan? plan(
    rust.ResumeQueue queue, {
    Set<int> missing = const <int>{},
  }) => ProgressApi.plan(
    saved: queue,
    // 文件在不在由调用方决定：真机上用的是 File.existsSync，
    // 这里不碰磁盘，只按 id 列出「已经不在了」的那几首。
    exists: (path) => !missing.any((id) => path == '/m/$id.mp3'),
  );

  test('整队都还在：队列照原样、下标照原样', () {
    final result = plan(saved(ids: [1, 2, 3], index: 1, positionMs: 42000))!;

    expect(result.entries.map((e) => e.id), [1, 2, 3]);
    expect(result.entries.first.path, '/m/1.mp3', reason: '路径要带给引擎');
    expect(result.index, 1);
    expect(result.positionMs, 42000);
  });

  test('队里有文件已经没了：剔掉它，当前项跟着重新定位', () {
    // 第 2 首被删了，而上次听的正是它前面那首没动、听的又是第 3 首的情况：
    final result = plan(
      saved(ids: [1, 2, 3], index: 2, positionMs: 9000),
      missing: {2},
    )!;

    expect(result.entries.map((e) => e.id), [1, 3]);
    expect(result.index, 1, reason: '第 3 首从下标 2 挪到了 1');
    expect(result.positionMs, 9000);
  });

  test('「上次那一首」正好被删了：退回队首，进度清零', () {
    final result = plan(
      saved(ids: [1, 2, 3], index: 1, positionMs: 9000),
      missing: {2},
    )!;

    expect(result.entries.map((e) => e.id), [1, 3]);
    expect(result.index, 0, reason: '别把进度安在别人身上');
    expect(result.positionMs, 0);
  });

  test('整队都没了：没什么可接着放的', () {
    expect(plan(saved(ids: [1, 2]), missing: {1, 2}), isNull);
  });
}
