// 播放界面的用例：封面 / 标题 / 控制按钮 / 定时播放菜单 / 返回。
//
// 页面本身不碰 FFI：快照与封面加载器都是注入进来的，
// 所以这里跑的是纯 widget 逻辑，不需要 Rust 侧在场。
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/src/player_page.dart';
import 'package:musicplayer/src/rust/api/player.dart';
import 'package:musicplayer/src/sleep_timer.dart';

import 'fixtures.dart';

/// 播放界面的最小骨架：快照通知器 + 回调记录，不依赖任何真实播放。
class _PlayerHarness {
  _PlayerHarness({PlayerSnapshot? snapshot})
    : player = ValueNotifier<PlayerSnapshot?>(
        snapshot ?? fakeSnapshot(positionMs: 0),
      ),
      sleepTimer = SleepTimer(onFire: () {});

  final ValueNotifier<PlayerSnapshot?> player;
  final SleepTimer sleepTimer;

  /// 按调用顺序记录下来的按钮点击。
  final List<String> calls = [];

  /// 最后一次跳转的目标位置（毫秒）。
  int? seekedTo;

  /// 每次音量步进请求的格数（正数变大、负数变小）。
  final List<int> volumeSteps = [];

  /// 音量步进要回报的比例；默认 0.5。
  double? volumeRatio = 0.5;

  PlayerPage page({CoverLoader? loadCover}) => PlayerPage(
    player: player,
    trackById: (id) => id <= 0 ? null : fakeTrack(id: id),
    onToggle: () => calls.add('toggle'),
    onNext: () => calls.add('next'),
    onPrevious: () => calls.add('previous'),
    onSeek: (value) => seekedTo = value,
    onCycleRepeat: () => calls.add('repeat'),
    onToggleShuffle: () => calls.add('shuffle'),
    sleepTimer: sleepTimer,
    loadCover: loadCover ?? (_) async => null,
    stepVolume: (steps) async {
      volumeSteps.add(steps);
      return volumeRatio;
    },
  );

  Widget build({CoverLoader? loadCover}) =>
      MaterialApp(home: page(loadCover: loadCover));

  void dispose() {
    sleepTimer.dispose();
    player.dispose();
  }
}

void main() {
  testWidgets('展示封面占位、标题、艺术家与两端时间', (tester) async {
    final harness = _PlayerHarness();
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.build());

    expect(find.text('测试曲目'), findsOneWidget);
    expect(find.text('某位歌手 · 某张专辑'), findsOneWidget);
    expect(find.byIcon(Icons.music_note), findsOneWidget, reason: '没有封面时用占位图');
    expect(find.text('0:00'), findsOneWidget, reason: '开头是 0:00 而不是 --:--');
    expect(find.text('3:20'), findsOneWidget, reason: '总时长 200000ms');

    // 没有任何封面可加载时，界面照样能用（不该抛异常）。
    expect(tester.takeException(), isNull);
  });

  testWidgets('封面按曲目缓存：快照每 500ms 刷新不会重复读图', (tester) async {
    var loads = 0;
    final harness = _PlayerHarness();
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      harness.build(
        loadCover: (_) async {
          loads += 1;
          return null;
        },
      ),
    );
    expect(loads, 1);

    // 模拟两轮轮询：换了位置但没换曲目，不该再读一次封面。
    harness.player.value = fakeSnapshot(positionMs: 1000);
    await tester.pump();
    harness.player.value = fakeSnapshot(positionMs: 1500);
    await tester.pump();
    expect(loads, 1, reason: '同一首曲目只该读一次封面');
  });

  testWidgets('上一曲 / 播放暂停 / 下一曲 / 随机 / 循环都接到回调', (tester) async {
    final harness = _PlayerHarness();
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.build());

    await tester.tap(find.byTooltip('上一首'));
    await tester.tap(find.byTooltip('下一首'));
    await tester.tap(find.byTooltip('暂停'));
    await tester.tap(find.byTooltip('随机播放：关（点击开启）'));
    await tester.tap(find.byTooltip('循环：关闭（点击切换）'));

    expect(harness.calls, ['previous', 'next', 'toggle', 'shuffle', 'repeat']);
  });

  testWidgets('拖动进度条会把目标位置交出去', (tester) async {
    final harness = _PlayerHarness();
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.build());

    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChanged!(60000);
    slider.onChangeEnd!(60000);

    expect(harness.seekedTo, 60000);
  });

  testWidgets('封面上右滑是上一曲、左滑是下一曲', (tester) async {
    final harness = _PlayerHarness();
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.build());

    // 向右甩：回到上一曲。
    await tester.fling(find.byKey(coverSwipeKey), const Offset(200, 0), 1000);
    await tester.pumpAndSettle();
    expect(harness.calls, ['previous']);
    expect(find.text('上一曲'), findsOneWidget, reason: '封面上应闪一下提示');

    // 向左甩：切到下一曲。
    await tester.fling(find.byKey(coverSwipeKey), const Offset(-200, 0), 1000);
    await tester.pumpAndSettle();
    expect(harness.calls, ['previous', 'next']);
    expect(find.text('下一曲'), findsOneWidget);

    // 提示是临时的：一秒后自己淡出。
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('下一曲'), findsOneWidget, reason: '内容留着，只是透明度变 0');
    final bubble = tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
    expect(bubble.opacity, 0);
  });

  testWidgets('封面滑动太小不算换曲（避免抹一下就跳歌）', (tester) async {
    final harness = _PlayerHarness();
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.build());

    // 慢慢拖一小段：速度低于阈值。
    await tester.drag(find.byKey(coverSwipeKey), const Offset(-40, 0));
    await tester.pumpAndSettle();

    expect(harness.calls, isEmpty);
  });

  testWidgets('封面上滑调大音量、下滑调小音量，并显示百分比', (tester) async {
    final harness = _PlayerHarness()..volumeRatio = 0.6;
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.build());

    await tester.fling(find.byKey(coverSwipeKey), const Offset(0, -200), 1000);
    await tester.pumpAndSettle();

    expect(harness.volumeSteps, [1], reason: '上滑＝音量 +1 格');
    expect(find.text('音量 60%'), findsOneWidget);

    await tester.fling(find.byKey(coverSwipeKey), const Offset(0, 200), 1000);
    await tester.pumpAndSettle();

    expect(harness.volumeSteps, [1, -1], reason: '下滑＝音量 -1 格');
    expect(find.text('音量 60%'), findsOneWidget);
    expect(harness.calls, isEmpty, reason: '调音量不该影响播放状态');
  });

  testWidgets('平台侧拿不到音量时不弹提示（也别崩）', (tester) async {
    final harness = _PlayerHarness()..volumeRatio = null;
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.build());

    await tester.fling(find.byKey(coverSwipeKey), const Offset(0, -200), 1000);
    await tester.pumpAndSettle();

    expect(harness.volumeSteps, [1], reason: '请求照样发出去了');
    expect(find.textContaining('音量'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('定时播放：选 30 分钟之后按钮上显示剩余时间，还能再关掉', (tester) async {
    // 默认测试窗口只有 800×600，7 个选项的底部弹窗会被挤出屏幕；
    // 换成接近真机的尺寸（1080×2400 @3x → 360×800 逻辑像素），
    // 真机上弹窗高度上限是屏幕的 9/16，放得下这几项。
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final harness = _PlayerHarness();
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.build());
    expect(find.byIcon(Icons.timer_outlined), findsOneWidget, reason: '默认是描边秒表');

    await tester.tap(find.byTooltip('定时播放：关闭（点击设置）'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // 等菜单弹出
    await tester.tap(find.text('30 分钟'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // 等菜单收起

    expect(harness.sleepTimer.isActive, isTrue);
    expect(find.text('30:00'), findsOneWidget, reason: '按钮上应显示剩余时间');
    expect(find.byIcon(Icons.timer_outlined), findsNothing);
    expect(find.text('关闭定时'), findsNothing, reason: '上一个弹窗应该已经收起');

    // 再点一次 → 关闭定时（点按钮上那串剩余时间，它就是这个按钮的内容）
    await tester.tap(find.text('30:00'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('关闭定时'), findsOneWidget, reason: '应该又弹出了菜单');
    await tester.tap(find.text('关闭定时'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(harness.sleepTimer.isActive, isFalse);
    expect(find.byIcon(Icons.timer_outlined), findsOneWidget);
  });

  testWidgets('左上角返回按钮回到上一页', (tester) async {
    final harness = _PlayerHarness();
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => harness.page()),
                ),
                child: const Text('打开播放界面'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开播放界面'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('返回播放列表'), findsOneWidget);

    await tester.tap(find.byTooltip('返回播放列表'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('返回播放列表'), findsNothing);
    expect(find.text('打开播放界面'), findsOneWidget);
  });
}
