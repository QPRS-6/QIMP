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

  /// 每次「设音量」请求的比例（0..1，按调用顺序）。
  final List<double> volumeSets = [];

  /// 读到的当前音量；null 表示平台侧读不到。
  double? volumeRead = 0.5;

  /// 置 true 表示平台侧改音量失败（返回 null）。
  bool volumeSetFails = false;

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
    readVolume: () async => volumeRead,
    setVolume: (ratio) async {
      volumeSets.add(ratio);
      return volumeSetFails ? null : ratio;
    },
  );

  Widget build({CoverLoader? loadCover}) =>
      MaterialApp(home: page(loadCover: loadCover));

  void dispose() {
    sleepTimer.dispose();
    player.dispose();
  }
}

/// 在封面上按住并纵向滑一段距离，返回还按着的手势（由调用方决定何时松手）。
///
/// [up] 是**真正参与音量换算**的距离（向上为正）。实现上先走 40 像素把纵向识别器
/// “唤醒”，这段抖动区在 Flutter 默认的 DragStartBehavior.start 下不会作为位移下发，
/// 所以后面那一下的距离就是干净的整数，验证“滑多少调多少”时不受框架细节干扰。
Future<TestGesture> _startVolumeDrag(WidgetTester tester, double up) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.byKey(coverSwipeKey)),
  );
  await gesture.moveBy(Offset(0, -40 * up.sign));
  await gesture.moveBy(Offset(0, -up));
  await tester.pump();
  return gesture;
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

  testWidgets('封面上滑按滑动距离线性调大音量、下滑线性调小，并跟手显示百分比', (tester) async {
    final harness = _PlayerHarness()..volumeRead = 0.5;
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.build());

    // 往上滑 60 像素：0.5 + 60/320 = 0.6875 → 69%
    final up = await _startVolumeDrag(tester, 60);
    expect(find.text('音量 69%'), findsOneWidget, reason: '拖动中就要跟手显示');
    await up.up();
    await tester.pumpAndSettle();

    expect(harness.volumeSets.single, 0.6875, reason: '滑 60 像素：0.5 → 0.6875');
    expect(find.text('音量 69%'), findsOneWidget);
    expect(harness.calls, isEmpty, reason: '调音量不该影响播放状态');

    // 反过来往下滑 80 像素：0.5 - 80/320 = 0.25
    final down = await _startVolumeDrag(tester, -80);
    await down.up();
    await tester.pumpAndSettle();

    expect(harness.volumeSets, [0.6875, 0.25], reason: '滑 80 像素：0.5 → 0.25');
    expect(find.text('音量 25%'), findsOneWidget);
  });

  testWidgets('音量滑到头会夹在 0% / 100%，不会算到外面去', (tester) async {
    final harness = _PlayerHarness()..volumeRead = 0.9;
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.build());

    // 0.9 + 200/320 > 1：应该停在满格。
    final up = await _startVolumeDrag(tester, 200);
    await up.up();
    await tester.pumpAndSettle();

    expect(harness.volumeSets, [1.0]);
    expect(find.text('音量 100%'), findsOneWidget);

    // 换一个很低的起点往下滑一大截：不该出现负数。
    harness.volumeRead = 0.1;
    final down = await _startVolumeDrag(tester, -200);
    await down.up();
    await tester.pumpAndSettle();

    expect(harness.volumeSets, [1.0, 0.0]);
    expect(find.text('音量 0%'), findsOneWidget);
  });

  testWidgets('封面只是轻轻碰一下（抖动区之内）不动音量', (tester) async {
    final harness = _PlayerHarness();
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.build());

    await tester.drag(find.byKey(coverSwipeKey), const Offset(0, -6));
    await tester.pumpAndSettle();

    expect(harness.volumeSets, isEmpty, reason: '走 6 像素还不够判定成“调音量”');
    expect(find.textContaining('音量'), findsNothing);
    expect(harness.calls, isEmpty, reason: '也不该被当成换曲');
  });

  testWidgets('平台侧读不到当前音量时不动它（也别崩）', (tester) async {
    final harness = _PlayerHarness()..volumeRead = null;
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.build());

    final up = await _startVolumeDrag(tester, 160);
    await up.up();
    await tester.pumpAndSettle();

    expect(harness.volumeSets, isEmpty, reason: '没有基准就别乱设，免得把音量拉到 0');
    expect(find.textContaining('音量'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('平台侧设置失败时不弹提示（也别崩）', (tester) async {
    final harness = _PlayerHarness()..volumeSetFails = true;
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.build());

    final up = await _startVolumeDrag(tester, 60);
    await up.up();
    await tester.pumpAndSettle();

    expect(harness.volumeSets, [0.6875], reason: '请求照样发出去了');
    // 拖动中那个预测值要收起来：平台侧没改成功，别让用户以为已经生效。
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      0,
    );
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
