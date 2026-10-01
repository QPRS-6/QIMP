// 播放条手感的用例：核心是「点进度条后不能弹回旧位置」。
//
// 这个时序在真机上很难截图复现（要抢在播放线程消化口令之前），
// 但在这里可以精确构造：跳转之后的那几次快照仍然是旧位置。
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/src/now_playing_bar.dart';
import 'package:musicplayer/src/rust/api/player.dart';

import 'fixtures.dart';

/// 循环按钮：按钮里唯一 tooltip 以「循环」开头的那个。
IconButton _repeatButton(WidgetTester tester) =>
    tester.widgetList<IconButton>(find.byType(IconButton)).firstWhere(
      (button) => (button.tooltip ?? '').startsWith('循环'),
    );

/// 随机播放按钮：唯一 tooltip 以「随机播放」开头的那个。
IconButton _shuffleButton(WidgetTester tester) =>
    tester.widgetList<IconButton>(find.byType(IconButton)).firstWhere(
      (button) => (button.tooltip ?? '').startsWith('随机播放'),
    );

/// 曲库页接线的最小骨架。
///
/// `trackDurationMs` 是**曲库**里记的时长（默认与夹具一致）；给 0 就是
/// 「曲库不知道这首歌多长」——真机上那种从 mp4 扒出来的音频就是这样。
Widget _harness({
  required PlayerSnapshot snapshot,
  required List<int> seeked,
  int trackDurationMs = fakeDurationMs,
  VoidCallback? onOpenPlayer,
  VoidCallback? onToggleShuffle,
}) => MaterialApp(
  home: Scaffold(
    bottomNavigationBar: NowPlayingBar(
      snapshot: snapshot,
      track: snapshot.trackId == 0
          ? null
          : fakeTrack(id: snapshot.trackId, durationMs: trackDurationMs),
      onToggle: () {},
      onNext: () {},
      onPrevious: () {},
      onSeek: seeked.add,
      onCycleRepeat: () {},
      onToggleShuffle: onToggleShuffle ?? () {},
      onOpenPlayer: onOpenPlayer ?? () {},
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
      _harness(snapshot: fakeSnapshot(positionMs: 10000), seeked: seeked),
    );
    expect(_sliderValue(tester), 10000);

    _tapSlider(tester, 120000);
    await tester.pump();
    expect(seeked, [120000], reason: '松手就该把跳转交给引擎');
    expect(_sliderValue(tester), 120000, reason: '松手后应停在目标位置');

    // 关键时序：跳转后的前两次轮询还是旧位置（引擎尚未追上）。
    await tester.pumpWidget(
      _harness(snapshot: fakeSnapshot(positionMs: 10100), seeked: seeked),
    );
    expect(_sliderValue(tester), 120000, reason: '引擎没追上时不能弹回旧位置');
    await tester.pumpWidget(
      _harness(snapshot: fakeSnapshot(positionMs: 10150), seeked: seeked),
    );
    expect(_sliderValue(tester), 120000);

    // 引擎追上（精确跳转落在包边界上，允许差一点）：交还给轮询值。
    await tester.pumpWidget(
      _harness(snapshot: fakeSnapshot(positionMs: 119800), seeked: seeked),
    );
    expect(_sliderValue(tester), 119800, reason: '追上后应显示真实位置');
  });

  testWidgets('跳转一直不生效时会把控制权还回去', (tester) async {
    final seeked = <int>[];
    await tester.pumpWidget(
      _harness(snapshot: fakeSnapshot(positionMs: 10000), seeked: seeked),
    );

    _tapSlider(tester, 120000);
    await tester.pump();
    expect(_sliderValue(tester), 120000);

    // 引擎始终停在原地：连续几次轮询之后必须认账，不能一直锁着骗用户。
    for (var i = 0; i < 6; i++) {
      await tester.pumpWidget(
        _harness(snapshot: fakeSnapshot(positionMs: 10000), seeked: seeked),
      );
    }
    expect(_sliderValue(tester), 10000, reason: '追不上就该显示真实位置');
  });

  testWidgets('换到下一首后不再锁着旧的跳转目标', (tester) async {
    final seeked = <int>[];
    await tester.pumpWidget(
      _harness(snapshot: fakeSnapshot(positionMs: 10000), seeked: seeked),
    );

    _tapSlider(tester, 120000);
    await tester.pump();
    expect(_sliderValue(tester), 120000);

    // 自动续播到下一首：位置回到 0，进度条必须跟着走。
    await tester.pumpWidget(
      _harness(snapshot: fakeSnapshot(trackId: 8, positionMs: 0), seeked: seeked),
    );
    expect(_sliderValue(tester), 0);
  });

  testWidgets('拖动过程中轮询值不会把滑块抢走', (tester) async {
    final seeked = <int>[];
    await tester.pumpWidget(
      _harness(snapshot: fakeSnapshot(positionMs: 10000), seeked: seeked),
    );

    tester.widget<Slider>(find.byType(Slider)).onChanged!(60000);
    await tester.pump();
    expect(_sliderValue(tester), 60000);

    // 还没松手就来了一次轮询：仍然跟手。
    await tester.pumpWidget(
      _harness(snapshot: fakeSnapshot(positionMs: 10500), seeked: seeked),
    );
    expect(_sliderValue(tester), 60000);
    expect(seeked, isEmpty, reason: '没松手就不该跳转');
  });

  testWidgets('循环按钮绘制的是字体里真有的字形（不用 *_on 实心变体）', (tester) async {
    // 回归用例：单曲循环曾经用 Icons.repeat_one_on 表示，但随 Flutter 打包的
    // MaterialIcons 字体里没有 U+E522 的字形，界面上会渲染成一个纯色方块。
    // 所以：关闭 / 列表循环用 Icons.repeat，单曲循环用 Icons.repeat_one，
    // 靠颜色区分开与关。
    Future<void> pump(RepeatMode mode) => tester.pumpWidget(
      _harness(snapshot: fakeSnapshot(repeat: mode), seeked: <int>[]),
    );

    IconData iconOf(WidgetTester tester) =>
        (_repeatButton(tester).icon as Icon).icon!;

    await pump(RepeatMode.off);
    expect(iconOf(tester), Icons.repeat);
    expect(_repeatButton(tester).color, isNull, reason: '关闭时用默认的前景色');

    await pump(RepeatMode.all);
    expect(iconOf(tester), Icons.repeat, reason: '列表循环只靠颜色区分');

    await pump(RepeatMode.one);
    expect(iconOf(tester), Icons.repeat_one, reason: '「1」必须画得出来');
    expect(_repeatButton(tester).color, isNotNull, reason: '开启时点亮图标');
  });

  testWidgets('随机播放按钮：开关共用同一个图标，开启时点亮', (tester) async {
    // 与循环按钮同一个坑：Icons.shuffle_on(0xE5A2) 在随 Flutter 打包的
    // MaterialIcons 里没有字形（渲染成实心方块），所以开 / 关共用
    // Icons.shuffle，靠颜色与提示区分。
    Future<void> pump(bool shuffle) => tester.pumpWidget(
      _harness(snapshot: fakeSnapshot(shuffle: shuffle), seeked: <int>[]),
    );

    await pump(false);
    expect((_shuffleButton(tester).icon as Icon).icon, Icons.shuffle);
    expect(_shuffleButton(tester).color, isNull, reason: '关闭时用默认的前景色');
    expect(_shuffleButton(tester).tooltip, '随机播放：关（点击开启）');

    await pump(true);
    expect((_shuffleButton(tester).icon as Icon).icon, Icons.shuffle);
    expect(_shuffleButton(tester).color, isNotNull, reason: '开启时点亮图标');
    expect(_shuffleButton(tester).tooltip, '随机播放：开（点击关闭）');
  });

  testWidgets('随机开着时，单曲循环的提示会说明它按列表循环走', (tester) async {
    // 随机 + 单曲循环时，真正说话的是随机（见 `rust/audio` 的 PlayQueue::advance）：
    // 列表一轮放完会自动重开一轮，而不是同一首无限循环。提示里得说清楚。
    Future<void> pump(RepeatMode mode, {required bool shuffle}) =>
        tester.pumpWidget(
          _harness(
            snapshot: fakeSnapshot(repeat: mode, shuffle: shuffle),
            seeked: <int>[],
          ),
        );

    await pump(RepeatMode.one, shuffle: true);
    expect(
      _repeatButton(tester).tooltip,
      '循环：单曲循环（随机下按列表循环走，点击切换）',
    );

    // 关掉随机：回到普通文案（这时单曲循环才真的循环这一首）。
    await pump(RepeatMode.one, shuffle: false);
    expect(_repeatButton(tester).tooltip, '循环：单曲循环（点击切换）');

    // 另外两种模式不受随机影响。
    await pump(RepeatMode.all, shuffle: true);
    expect(_repeatButton(tester).tooltip, '循环：列表循环（点击切换）');
    await pump(RepeatMode.off, shuffle: true);
    expect(_repeatButton(tester).tooltip, '循环：关闭（点击切换）');
  });

  testWidgets('继续播放的状态：显示上次那首、停在原进度、并标明没在响', (tester) async {
    // 启动时把上次那一首装进引擎（不播放）之后，播放条就是长这样：
    // 用户点一下 ▶ 才接着出声。
    await tester.pumpWidget(
      _harness(
        snapshot: fakeSnapshot(positionMs: 42000, state: PlayerState.paused),
        seeked: <int>[],
      ),
    );

    expect(find.text('测试曲目'), findsOneWidget);
    expect(find.textContaining('已暂停'), findsOneWidget, reason: '要能看出它还没响');
    expect(_sliderValue(tester), 42000, reason: '进度条应停在「上次听到哪儿」');
  });

  testWidgets('点标题区域打开播放界面；没有曲目时点不动', (tester) async {
    var opened = 0;
    await tester.pumpWidget(
      _harness(
        snapshot: fakeSnapshot(positionMs: 10000),
        seeked: <int>[],
        onOpenPlayer: () => opened += 1,
      ),
    );
    await tester.tap(find.text('测试曲目'));
    expect(opened, 1, reason: '点标题应该打开全屏播放界面');

    // 停止状态（trackId 为 0）时播放条上没有曲目可看，点标题不该跳转。
    await tester.pumpWidget(
      _harness(
        snapshot: fakeSnapshot(trackId: 0),
        seeked: <int>[],
        onOpenPlayer: () => opened += 1,
      ),
    );
    await tester.tap(find.text('没有在播放'));
    expect(opened, 1, reason: '没有曲目时不该打开播放界面');
  });

  testWidgets('暂停状态下跳转也能锁住目标位置', (tester) async {
    final seeked = <int>[];
    await tester.pumpWidget(
      _harness(
        snapshot: fakeSnapshot(positionMs: 10000, state: PlayerState.paused),
        seeked: seeked,
      ),
    );

    _tapSlider(tester, 30000);
    await tester.pump();
    // 暂停时引擎位置本来就不动，只能靠上一次的位置判断：先不要弹回去。
    await tester.pumpWidget(
      _harness(
        snapshot: fakeSnapshot(positionMs: 10000, state: PlayerState.paused),
        seeked: seeked,
      ),
    );
    expect(_sliderValue(tester), 30000);

    // 引擎把位置挪到目标附近（暂停状态下的跳转结果）。
    await tester.pumpWidget(
      _harness(
        snapshot: fakeSnapshot(positionMs: 29800, state: PlayerState.paused),
        seeked: seeked,
      ),
    );
    expect(_sliderValue(tester), 29800);
  });

  testWidgets('曲库没记时长时，用解码器算出来的那份：进度条照样能用', (tester) async {
    // 真机上遇到的：从 mp4 扒出来、名字叫 `.mp3` 的音频，标签里读不出时长
    // （曲库那份是 0），但解码器知道它是 336 秒。
    await tester.pumpWidget(
      _harness(
        snapshot: fakeSnapshot(positionMs: 20038, durationMs: 336967),
        seeked: <int>[],
        trackDurationMs: 0,
      ),
    );

    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.max, 336967, reason: '总长该用引擎那份');
    expect(slider.value, 20038);
    expect(slider.onChanged, isNotNull, reason: '知道总长就该能拖');
    expect(find.textContaining('5:37'), findsOneWidget, reason: '副标题也要报出总长');
  });

  testWidgets('两份都不知道时长时不能崩，只是不给拖', (tester) async {
    // 回归用例：这里曾经给 `value` 用了 `double.maxFinite` 当上界，于是
    // 「时长未知 + 已经在播」时 value(20038) > max(1)，Flutter 直接断言失败，
    // 真机上整个界面变成一屏红字。
    await tester.pumpWidget(
      _harness(
        snapshot: fakeSnapshot(positionMs: 20038),
        seeked: <int>[],
        trackDurationMs: 0,
      ),
    );

    expect(tester.takeException(), isNull, reason: '时长未知也不该崩');
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.value, 0, reason: '不知道总长，进度条只能画成空的');
    expect(slider.onChanged, isNull, reason: '不给拖到没有意义的位置');
    expect(find.textContaining('--:--'), findsOneWidget);
  });
}
