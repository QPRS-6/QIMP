// 播放条手感的用例：核心是「点进度条后不能弹回旧位置」。
//
// 这个时序在真机上很难截图复现（要抢在播放线程消化口令之前），
// 但在这里可以精确构造：跳转之后的那几次快照仍然是旧位置。
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/src/now_playing_bar.dart';
import 'package:musicplayer/src/rust/api/library.dart';
import 'package:musicplayer/src/rust/api/player.dart';

/// 假曲目时长（进度条按它算总长）。
const int _durationMs = 200000;

Track _track({int id = 7, int durationMs = _durationMs}) => Track(
  id: id,
  path: '/storage/emulated/0/Music/test.mp3',
  title: '测试曲目',
  artist: '某位歌手',
  album: '某张专辑',
  durationMs: durationMs,
  sizeBytes: 1024,
  modifiedAt: 0,
  hasCover: false,
  addedAt: 0,
);

PlayerSnapshot _snapshot({
  int trackId = 7,
  int positionMs = 0,
  PlayerState state = PlayerState.playing,
}) => PlayerSnapshot(
  state: state,
  positionMs: positionMs,
  index: 0,
  queueLen: 1,
  trackId: trackId,
  repeat: RepeatMode.off,
);

/// 曲库页接线的最小骨架。
Widget _harness({required PlayerSnapshot snapshot, required List<int> seeked}) =>
    MaterialApp(
      home: Scaffold(
        bottomNavigationBar: NowPlayingBar(
          snapshot: snapshot,
          track: snapshot.trackId == 0 ? null : _track(id: snapshot.trackId),
          onToggle: () {},
          onNext: () {},
          onPrevious: () {},
          onSeek: seeked.add,
          onCycleRepeat: () {},
        ),
      ),
    );

double _sliderValue(WidgetTester tester) =>
    tester.widget<Slider>(find.byType(Slider)).value;

/// 模拟点进度条：Flutter 的 Slider 点击等价于「按下即跳 + 抬手生效」。
void _tapSlider(WidgetTester tester, double value) {
  final slider = tester.widget<Slider>(find.byType(Slider));
  slider.onChanged!(value);
  slider.onChangeEnd!(value);
}

void main() {
  testWidgets('松手后锁在目标位置，不会先弹回旧位置', (tester) async {
    final seeked = <int>[];
    await tester.pumpWidget(
      _harness(snapshot: _snapshot(positionMs: 10000), seeked: seeked),
    );
    expect(_sliderValue(tester), 10000);

    _tapSlider(tester, 120000);
    await tester.pump();
    expect(seeked, [120000], reason: '松手就该把跳转交给引擎');
    expect(_sliderValue(tester), 120000, reason: '松手后应停在目标位置');

    // 关键时序：跳转后的前两次轮询还是旧位置（引擎尚未追上）。
    await tester.pumpWidget(
      _harness(snapshot: _snapshot(positionMs: 10100), seeked: seeked),
    );
    expect(_sliderValue(tester), 120000, reason: '引擎没追上时不能弹回旧位置');
    await tester.pumpWidget(
      _harness(snapshot: _snapshot(positionMs: 10150), seeked: seeked),
    );
    expect(_sliderValue(tester), 120000);

    // 引擎追上（精确跳转落在包边界上，允许差一点）：交还给轮询值。
    await tester.pumpWidget(
      _harness(snapshot: _snapshot(positionMs: 119800), seeked: seeked),
    );
    expect(_sliderValue(tester), 119800, reason: '追上后应显示真实位置');
  });

  testWidgets('跳转一直不生效时会把控制权还回去', (tester) async {
    final seeked = <int>[];
    await tester.pumpWidget(
      _harness(snapshot: _snapshot(positionMs: 10000), seeked: seeked),
    );

    _tapSlider(tester, 120000);
    await tester.pump();
    expect(_sliderValue(tester), 120000);

    // 引擎始终停在原地：连续几次轮询之后必须认账，不能一直锁着骗用户。
    for (var i = 0; i < 6; i++) {
      await tester.pumpWidget(
        _harness(snapshot: _snapshot(positionMs: 10000), seeked: seeked),
      );
    }
    expect(_sliderValue(tester), 10000, reason: '追不上就该显示真实位置');
  });

  testWidgets('换到下一首后不再锁着旧的跳转目标', (tester) async {
    final seeked = <int>[];
    await tester.pumpWidget(
      _harness(snapshot: _snapshot(positionMs: 10000), seeked: seeked),
    );

    _tapSlider(tester, 120000);
    await tester.pump();
    expect(_sliderValue(tester), 120000);

    // 自动续播到下一首：位置回到 0，进度条必须跟着走。
    await tester.pumpWidget(
      _harness(snapshot: _snapshot(trackId: 8, positionMs: 0), seeked: seeked),
    );
    expect(_sliderValue(tester), 0);
  });

  testWidgets('拖动过程中轮询值不会把滑块抢走', (tester) async {
    final seeked = <int>[];
    await tester.pumpWidget(
      _harness(snapshot: _snapshot(positionMs: 10000), seeked: seeked),
    );

    tester.widget<Slider>(find.byType(Slider)).onChanged!(60000);
    await tester.pump();
    expect(_sliderValue(tester), 60000);

    // 还没松手就来了一次轮询：仍然跟手。
    await tester.pumpWidget(
      _harness(snapshot: _snapshot(positionMs: 10500), seeked: seeked),
    );
    expect(_sliderValue(tester), 60000);
    expect(seeked, isEmpty, reason: '没松手就不该跳转');
  });

  testWidgets('暂停状态下跳转也能锁住目标位置', (tester) async {
    final seeked = <int>[];
    await tester.pumpWidget(
      _harness(
        snapshot: _snapshot(positionMs: 10000, state: PlayerState.paused),
        seeked: seeked,
      ),
    );

    _tapSlider(tester, 30000);
    await tester.pump();
    // 暂停时引擎位置本来就不动，只能靠上一次的位置判断：先不要弹回去。
    await tester.pumpWidget(
      _harness(
        snapshot: _snapshot(positionMs: 10000, state: PlayerState.paused),
        seeked: seeked,
      ),
    );
    expect(_sliderValue(tester), 30000);

    // 引擎把位置挪到目标附近（暂停状态下的跳转结果）。
    await tester.pumpWidget(
      _harness(
        snapshot: _snapshot(positionMs: 29800, state: PlayerState.paused),
        seeked: seeked,
      ),
    );
    expect(_sliderValue(tester), 29800);
  });
}
