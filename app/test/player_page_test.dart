// 播放界面的用例：封面 / 标题 / 控制按钮 / 定时播放菜单 / 返回。
//
// 页面本身不碰 FFI：快照与封面加载器都是注入进来的，
// 所以这里跑的是纯 widget 逻辑，不需要 Rust 侧在场。
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/src/lyrics_view.dart';
import 'package:musicplayer/src/player_page.dart';
import 'package:musicplayer/src/queue_view.dart';
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

  /// 当前播放队列（底部那个半屏列表读它）。
  final ValueNotifier<List<QueueEntry>> queue = ValueNotifier<List<QueueEntry>>(
    const <QueueEntry>[],
  );

  /// 按调用顺序记录下来的按钮点击。
  final List<String> calls = [];

  /// 最后一次跳转的目标位置（毫秒）。
  int? seekedTo;

  /// 从队列里点走的那些下标（按顺序）。
  final List<int> jumpedTo = [];

  /// 每次「设音量」请求的比例（0..1，按调用顺序）。
  final List<double> volumeSets = [];

  /// 读到的当前音量；null 表示平台侧读不到。
  double? volumeRead = 0.5;

  /// 置 true 表示平台侧改音量失败（返回 null）。
  bool volumeSetFails = false;

  PlayerPage page({CoverLoader? loadCover, LyricsLoader? loadLyrics}) =>
      PlayerPage(
        player: player,
        queue: queue,
        trackById: (id) => id <= 0 ? null : fakeTrack(id: id),
        onToggle: () => calls.add('toggle'),
        onNext: () => calls.add('next'),
        onPrevious: () => calls.add('previous'),
        onSeek: (value) => seekedTo = value,
        onJump: jumpedTo.add,
        onCycleRepeat: () => calls.add('repeat'),
        onToggleShuffle: () => calls.add('shuffle'),
        sleepTimer: sleepTimer,
        loadCover: loadCover ?? (_) async => null,
        // 默认“这首歌没有歌词”：只有歌词相关的用例才需要注入内容。
        loadLyrics: loadLyrics ?? (_) async => null,
        readVolume: () async => volumeRead,
        setVolume: (ratio) async {
          volumeSets.add(ratio);
          return volumeSetFails ? null : ratio;
        },
      );

  Widget build({CoverLoader? loadCover, LyricsLoader? loadLyrics}) =>
      MaterialApp(
        home: page(loadCover: loadCover, loadLyrics: loadLyrics),
      );

  void dispose() {
    sleepTimer.dispose();
    player.dispose();
    queue.dispose();
  }
}

/// 当前测试窗口。
///
/// `setUp` / `tearDown` 里拿不到 `tester`，只能从 binding 上取（`tester.view`
/// 拿的就是同一个东西）。
TestFlutterView _testView() => TestWidgetsFlutterBinding.ensureInitialized()
    .platformDispatcher
    .implicitView!;

/// 平板窗口：1600×2560 @2x → 逻辑 800×1280（最短边 800 ≥ 600）。
///
/// 这个文件默认跑在手机窗口里（见 `main` 里的 `setUp`），平板那几个用例
/// 自己把它换掉。
void _useTabletWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1600, 2560);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
}

/// 手机横屏窗口：2400×1080 @3x → 逻辑 800×360（最短边 360，还是手机）。
///
/// 横屏手机上播放界面走「左封面 / 右控制」那一套（见 `player_page`）。
void _useLandscapePhoneWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(2400, 1080);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

/// 在封面上按住并纵向滑一段距离，返回还按着的手势（由调用方决定何时松手）。
///
/// [up] 是**真正参与音量换算**的距离（向上为正）。实现上先走 40 像素把纵向识别器
/// “唤醒”，这段抖动区在 Flutter 默认的 DragStartBehavior.start 下不会作为位移下发，
/// 所以后面那一下的距离就是干净的整数，验证“滑多少调多少”时不受框架细节干扰。
Future<TestGesture> _startVolumeDrag(WidgetTester tester, double up) =>
    _startVolumeDragFrom(
      tester,
      tester.getCenter(find.byKey(coverSwipeKey)),
      up,
    );

/// 同上，但可以指定起点：用来验证「图外面那块空白没有音量手势」。
Future<TestGesture> _startVolumeDragFrom(
  WidgetTester tester,
  Offset start,
  double up,
) async {
  final gesture = await tester.startGesture(start);
  await gesture.moveBy(Offset(0, -40 * up.sign));
  await gesture.moveBy(Offset(0, -up));
  await tester.pump();
  return gesture;
}

/// 进歌词页：点封面左上角那个按钮。
///
/// 比模拟滑动稳（滑动的手势分区另有专门的用例），其余用例关心的是歌词页里的行为。
Future<void> openLyrics(WidgetTester tester) async {
  await tester.tap(find.byTooltip('歌词'));
  await tester.pumpAndSettle();
}

void main() {
  // 这个文件里的用例默认都跑在**手机窗口**里。
  //
  // 框架默认的测试窗口是 800×600 逻辑像素——最短边正好 600，按
  // `useTabletLayout` 会被判成平板，而下面绝大多数用例测的都是手机上那一套
  // （封面页 / 歌词页二选一）。所以统一换成 1080×2400 @3x：真机上就是 360×800。
  // 平板的用例自己换窗口（[_useTabletWindow]）。
  setUp(() {
    _testView()
      ..physicalSize = const Size(1080, 2400)
      ..devicePixelRatio = 3;
  });
  tearDown(() => _testView().reset());

  testWidgets('展示封面占位、标题、艺术家与两端时间', (tester) async {
    final harness = _PlayerHarness();
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.build());

    // 曲名出现在两处：顶栏（歌词页那边唯一的曲名来源）与正文那行大标题。
    expect(find.text('测试曲目'), findsNWidgets(2));
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

  testWidgets('「下一曲」右边的播放列表按钮：底部弹出半屏队列，点一首就跳过去', (tester) async {
    final harness = _PlayerHarness();
    addTearDown(harness.dispose);
    harness.queue.value = const <QueueEntry>[
      QueueEntry(id: 7, path: '/storage/emulated/0/Music/a.mp3'),
      QueueEntry(id: 8, path: '/storage/emulated/0/Music/b.mp3'),
    ];

    await tester.pumpWidget(harness.build());

    // 弹窗还没叫出来之前，队列内容不该占着播放界面。
    expect(find.byType(ListTile), findsNothing);

    await tester.tap(find.byTooltip('播放列表'));
    await tester.pumpAndSettle();

    // 半屏：列表区域正好占屏幕高度的一半。
    final screenHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(tester.getSize(find.byType(QueueView)).height, screenHeight / 2);

    expect(find.text('队列 2 首 · 正在放第 1 首'), findsOneWidget);
    expect(find.byType(ListTile), findsNWidgets(2));

    // 点第二首：把下标交出去，并关掉弹窗（跳转结果在播放界面上立刻能看到）。
    await tester.tap(find.byType(ListTile).last);
    await tester.pumpAndSettle();
    expect(harness.jumpedTo, [1]);
    expect(find.byType(ListTile), findsNothing, reason: '点完就该收起弹窗');
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

  testWidgets('封面页的左右滑就是切歌，但不翻页（翻页只走按钮）', (tester) async {
    final harness = _PlayerHarness();
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.build());

    await tester.fling(find.byKey(coverSwipeKey), const Offset(200, 0), 1000);
    await tester.pumpAndSettle();
    expect(harness.calls, ['previous']);
    expect(find.text('上一曲'), findsOneWidget, reason: '封面上应闪一下提示');

    await tester.fling(find.byKey(coverSwipeKey), const Offset(-200, 0), 1000);
    await tester.pumpAndSettle();
    expect(harness.calls, ['previous', 'next']);
    expect(find.text('下一曲'), findsOneWidget);
    expect(find.byType(LyricsView), findsNothing, reason: '滑动不该翻到歌词页');
  });

  testWidgets('手势只认封面那张图：图外面的空白划了不算', (tester) async {
    final harness = _PlayerHarness();
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.build());

    // 起点取整块手势区的**右上角**：封面是居中的方块，这里在它外面。
    // （左上角现在摆着「歌词」按钮，那颗按钮自己会吃掉落在它身上的手势。）
    final outside =
        tester.getTopRight(find.byKey(playerSwipeKey)) + const Offset(-20, 20);

    // 横向：不该切歌，也不该翻页。
    await tester.flingFrom(outside, const Offset(-200, 0), 1000);
    await tester.pumpAndSettle();
    expect(harness.calls, isEmpty, reason: '空白处划一下不该换歌');
    expect(find.byType(LyricsView), findsNothing);
    expect(find.text('下一曲'), findsNothing, reason: '连提示气泡都不该出现');

    // 纵向：不该调音量（空白处没有音量手势）。
    final up = await _startVolumeDragFrom(tester, outside, 120);
    await up.up();
    await tester.pumpAndSettle();
    expect(harness.volumeSets, isEmpty, reason: '空白处纵向滑动不该动音量');
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌词页的滑动不切歌：右滑回封面，左滑什么都不做', (tester) async {
    final harness = _PlayerHarness();
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.build());
    await tester.tap(find.byTooltip('歌词'));
    await tester.pumpAndSettle();
    expect(find.byType(LyricsView), findsOneWidget);

    // 左滑：以前这里是「下一曲」，现在什么都不做（用户要求歌词页不切歌）。
    // 歌词页上认手势的是整块区域（`playerSwipeKey`）——封面那张图已经不在了。
    await tester.fling(find.byKey(playerSwipeKey), const Offset(-200, 0), 1000);
    await tester.pumpAndSettle();
    expect(harness.calls, isEmpty, reason: '歌词页的滑动不该切歌');
    expect(find.byType(LyricsView), findsOneWidget, reason: '也不该翻走');

    // 右滑：回封面页，同样不切歌。
    await tester.fling(find.byKey(playerSwipeKey), const Offset(200, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.byType(LyricsView), findsNothing);
    expect(harness.calls, isEmpty);
  });

  testWidgets('顶栏固定用深色、显示曲名（不是专辑名）', (tester) async {
    final harness = _PlayerHarness();
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.build());

    // 顶栏是曲名，不是专辑名（夹具里专辑叫「某张专辑」）。
    expect(find.text('测试曲目'), findsNWidgets(2), reason: '顶栏与正文都该是曲名');
    expect(find.text('某张专辑'), findsNothing, reason: '顶栏不该显示专辑名');
    expect(find.text('某位歌手 · 某张专辑'), findsOneWidget, reason: '副标题仍带着专辑');

    final coverBar = tester.widget<AppBar>(find.byType(AppBar));
    expect(coverBar.scrolledUnderElevation, 0, reason: '关掉 M3 的滚动染色');
    expect(coverBar.surfaceTintColor, Colors.transparent);

    // 切到歌词页：那边是个滚动列表，M3 本来会让 AppBar 自己变深——这里必须纹丝不动。
    await openLyrics(tester);
    final lyricsBar = tester.widget<AppBar>(find.byType(AppBar));
    expect(lyricsBar.backgroundColor, coverBar.backgroundColor);
    expect(lyricsBar.backgroundColor, isNotNull);
    expect(
      lyricsBar.backgroundColor,
      isNot(Theme.of(tester.element(find.byType(AppBar))).colorScheme.surface),
      reason: '固定成的是深的那一份，不是默认的浅色',
    );
  });

  testWidgets('封面左上角的按钮：点一下进歌词页，那边左上是回封面按钮', (tester) async {
    final harness = _PlayerHarness();
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.build());
    expect(find.byTooltip('歌词'), findsOneWidget);

    // 位置：封面的**左上角**（在封面中心的上方偏左）。
    final cover = tester.getRect(find.byKey(coverSwipeKey));
    final button = tester.getCenter(find.byTooltip('歌词'));
    expect(button.dx, lessThan(cover.center.dx));
    expect(button.dy, lessThan(cover.center.dy));

    await tester.tap(find.byTooltip('歌词'));
    await tester.pumpAndSettle();
    expect(find.byType(LyricsView), findsOneWidget);
    expect(find.byTooltip('歌词'), findsNothing, reason: '到了歌词页就换成返回按钮');

    // 歌词页那一行的「歌词」+ 图标已经删掉了（整页都是歌词，不用再标一遍）：
    // 只剩回封面这一颗，而且搬到了左上角——原来它靠右，横屏时正好贴着两栏的交界。
    expect(find.text('歌词'), findsNothing, reason: '不再标「歌词」');
    expect(find.byIcon(Icons.lyrics_outlined), findsNothing);
    final lyricsPage = tester.getRect(find.byType(LyricsView));
    final back = tester.getRect(find.byTooltip('回封面（右滑也可以）'));
    expect(back.center.dx, lessThan(lyricsPage.center.dx), reason: '按钮在左边');
    expect(back.center.dy, lessThan(lyricsPage.center.dy), reason: '在顶上一行');

    // 再点回去（歌词页那个按钮）。
    await tester.tap(find.byTooltip('回封面（右滑也可以）'));
    await tester.pumpAndSettle();
    expect(find.byType(LyricsView), findsNothing);
    expect(find.byTooltip('歌词'), findsOneWidget);
  });

  testWidgets('歌词页：当前句高亮、其余暗色，点一句就跳过去', (tester) async {
    final harness = _PlayerHarness(snapshot: fakeSnapshot(positionMs: 12_000));
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      harness.build(
        loadLyrics: (_) async => fakeLyrics(<(int, String)>[
          (5_000, '第一句'),
          (10_000, '第二句'),
          (20_000, '第三句'),
        ]),
      ),
    );
    await openLyrics(tester);

    expect(find.text('第一句'), findsOneWidget);
    expect(find.text('第三句'), findsOneWidget);

    // 12 秒时该亮第二句（最后一句 timeMs <= 位置的）。
    final active = tester.widget<Text>(find.text('第二句'));
    final inactive = tester.widget<Text>(find.text('第一句'));
    final theme = Theme.of(tester.element(find.text('第二句')));
    expect(active.style?.color, theme.colorScheme.primary);
    expect(inactive.style?.color, theme.colorScheme.onSurfaceVariant);

    // 点第三句：把它的时间交出去。
    await tester.tap(find.text('第三句'));
    await tester.pumpAndSettle();
    expect(harness.seekedTo, 20_000);
  });

  testWidgets('换句时把新的一句滚到中间', (tester) async {
    final harness = _PlayerHarness(snapshot: fakeSnapshot(positionMs: 0));
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      harness.build(
        loadLyrics: (_) async => fakeLyrics(<(int, String)>[
          for (var i = 0; i < 40; i++) (i * 1_000, '第 $i 句'),
        ]),
      ),
    );
    await openLyrics(tester);

    final controller = tester
        .widget<ListView>(find.byType(ListView))
        .controller!;
    expect(
      controller.offset,
      closeTo(kLyricLineHeight / 2, 1),
      reason: '第一句也被摆到中间',
    );

    // 播到第 20 句：列表要跟过去（行高固定，目标是这条的中心）。
    harness.player.value = fakeSnapshot(positionMs: 20_500);
    await tester.pumpAndSettle();
    expect(
      controller.offset,
      closeTo(20 * kLyricLineHeight + kLyricLineHeight / 2, 1),
      reason: '当前句应被滚到中间',
    );
  });

  testWidgets('同一时间戳的两行歌词当成一条：整条一起高亮、一起滚', (tester) async {
    final harness = _PlayerHarness(snapshot: fakeSnapshot(positionMs: 10_500));
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      harness.build(
        // core 会把同一时间点的两行合成一条（文本里是换行）。
        loadLyrics: (_) async => fakeLyrics(<(int, String)>[
          (5_000, '第一句'),
          (10_000, '原文一句\ntranslation'),
          (20_000, '第三句'),
        ]),
      ),
    );
    await openLyrics(tester);

    // 两行在同一个 Text 里，一次找到两个词。
    expect(find.textContaining('translation'), findsOneWidget);
    final entry = tester.widget<Text>(find.textContaining('translation'));
    final theme = Theme.of(tester.element(find.textContaining('translation')));
    expect(entry.style?.color, theme.colorScheme.primary, reason: '整条一起亮');
    expect(entry.maxLines, 2, reason: '两行都要显示出来，不能被截成一行');

    // 这条占两格高度：滚动位置按「两个行高」算。
    final heights = tester
        .widgetList<SizedBox>(find.byType(SizedBox))
        .map((box) => box.height)
        .whereType<double>()
        .toList();
    expect(heights, contains(kLyricLineHeight * 2), reason: '双行歌词占两格');

    final controller = tester
        .widget<ListView>(find.byType(ListView))
        .controller!;
    expect(
      controller.offset,
      closeTo(
        kLyricLineHeight + kLyricLineHeight, // 第二条的起点
        kLyricLineHeight / 2 + 1, // 再加它自己的一半
      ),
      reason: '双行那一条的中心才是「中间」',
    );
  });

  testWidgets('定时播放：自定义分钟数（含上下限校验）', (tester) async {
    final harness = _PlayerHarness();
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.build());
    await tester.tap(find.byTooltip('定时播放：关闭（点击设置）'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('自定义…'));
    await tester.pumpAndSettle();

    // 什么都没填：不能开始。
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '开始'))
          .onPressed,
      isNull,
      reason: '空输入不该能开始',
    );

    // 0 分钟没有意义（等于立刻暂停）：也不给过。
    await tester.enterText(find.byType(TextField), '0');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '开始'))
          .onPressed,
      isNull,
    );

    // 超过一天同样不给过。
    await tester.enterText(find.byType(TextField), '2000');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '开始'))
          .onPressed,
      isNull,
    );

    await tester.enterText(find.byType(TextField), '25');
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始'));
    await tester.pumpAndSettle();

    expect(harness.sleepTimer.isActive, isTrue);
    expect(find.text('25:00'), findsOneWidget, reason: '按钮上显示自定义的剩余时间');

    // 收尾：取消定时。不然那个每秒一跳的 Timer 会活到测试结束，框架会报 pending timer。
    harness.sleepTimer.cancel();
  });

  testWidgets('歌词页上纵向滑动不再调音量（留给歌词自己滚）', (tester) async {
    final harness = _PlayerHarness()..volumeRead = 0.5;
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      harness.build(
        loadLyrics: (_) async => fakeLyrics(<(int, String)>[
          for (var i = 0; i < 40; i++) (i * 1_000, '第 $i 句'),
        ]),
      ),
    );
    await openLyrics(tester);

    // 歌词页上认手势的是整块区域（封面那张图已经不在了）。
    final gesture = await _startVolumeDragFrom(
      tester,
      tester.getCenter(find.byKey(playerSwipeKey)),
      100,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(harness.volumeSets, isEmpty, reason: '这一页的上下滑动是滚歌词');
    expect(find.textContaining('音量'), findsNothing);
  });

  testWidgets('滑动提示是临时的：一秒后自己淡出', (tester) async {
    final harness = _PlayerHarness();
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.build());
    await tester.fling(find.byKey(coverSwipeKey), const Offset(200, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('上一曲'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('上一曲'), findsOneWidget, reason: '内容留着，只是透明度变 0');
    final bubble = tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
    expect(bubble.opacity, 0);
  });

  testWidgets('没有歌词时说清楚，并给出该放的 .lrc 路径', (tester) async {
    final harness = _PlayerHarness();
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.build());
    await openLyrics(tester);

    expect(find.text('这首歌没有歌词'), findsOneWidget);
    // 夹具里的路径是 /storage/emulated/0/Music/test.mp3。
    expect(
      find.textContaining('/storage/emulated/0/Music/test.lrc'),
      findsOneWidget,
    );
  });

  testWidgets('封面滑动太小不算换曲（避免抹一下就跳歌）', (tester) async {
    final harness = _PlayerHarness();
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.build());

    // 慢慢拖一小段：速度低于阈值。
    await tester.drag(find.byKey(coverSwipeKey), const Offset(-40, 0));
    await tester.pumpAndSettle();

    expect(harness.calls, isEmpty);
    expect(find.byType(LyricsView), findsNothing, reason: '也不该翻页');
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
    // 手机窗口（360×800 逻辑像素，见 `main` 里的 `setUp`）下 7 个选项放得下：
    // 真机上底部弹窗的高度上限是屏幕的 9/16。
    final harness = _PlayerHarness();
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.build());
    expect(
      find.byIcon(Icons.timer_outlined),
      findsOneWidget,
      reason: '默认是描边秒表',
    );

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
                onPressed: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute<void>(builder: (_) => harness.page())),
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

  // ---------- 平板：窗口最短边 ≥ 600，播放界面改成左右分栏 ----------

  testWidgets('平板：左边是控制、右边是歌词，两栏同时看得见（不用再翻页）', (tester) async {
    _useTabletWindow(tester);
    final harness = _PlayerHarness();
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      harness.build(
        loadLyrics: (_) async => fakeLyrics(<(int, String)>[(5_000, '第一句')]),
      ),
    );
    await tester.pumpAndSettle();

    // 歌词与封面同时在场：平板上没有「封面页 / 歌词页」之分。
    expect(find.byType(LyricsView), findsOneWidget);
    expect(find.byKey(coverSwipeKey), findsOneWidget);
    expect(find.text('第一句'), findsOneWidget);

    // 是**左右**分栏：歌词那一栏整个落在封面右边。
    final cover = tester.getRect(find.byKey(coverSwipeKey));
    final lyrics = tester.getRect(find.byType(LyricsView));
    expect(lyrics.left, greaterThanOrEqualTo(cover.right));

    // 翻页那两个按钮在平板上都没有意义，不该出现。
    expect(find.byTooltip('歌词'), findsNothing);
    expect(find.byTooltip('回封面（右滑也可以）'), findsNothing);

    // 播放控制仍在左边那一栏：进度条与按钮都还在。
    expect(find.byType(Slider), findsOneWidget);
    await tester.tap(find.byTooltip('下一首'));
    expect(harness.calls, ['next']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('平板：右边那栏的歌词照样高亮、点一句就跳过去', (tester) async {
    _useTabletWindow(tester);
    final harness = _PlayerHarness(snapshot: fakeSnapshot(positionMs: 12_000));
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      harness.build(
        loadLyrics: (_) async => fakeLyrics(<(int, String)>[
          (5_000, '第一句'),
          (10_000, '第二句'),
          (20_000, '第三句'),
        ]),
      ),
    );
    await tester.pumpAndSettle();

    // 12 秒时该亮第二句，与手机上那条规则完全一样（同一份 LyricsView）。
    final theme = Theme.of(tester.element(find.text('第二句')));
    expect(
      tester.widget<Text>(find.text('第二句')).style?.color,
      theme.colorScheme.primary,
    );
    expect(
      tester.widget<Text>(find.text('第一句')).style?.color,
      theme.colorScheme.onSurfaceVariant,
    );

    await tester.tap(find.text('第三句'));
    await tester.pumpAndSettle();
    expect(harness.seekedTo, 20_000);
  });

  testWidgets('平板横屏走的还是平板那一套：左边控制、右边常驻歌词', (tester) async {
    // 2560×1600 @2x → 逻辑 1280×800：横着的平板。
    // 横屏对手机是「左封面 / 右控制」，但平板上地方够，仍然按平板那一套来。
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final harness = _PlayerHarness();
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      harness.build(
        loadLyrics: (_) async => fakeLyrics(<(int, String)>[(5_000, '第一句')]),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(LyricsView), findsOneWidget, reason: '歌词不用点就看得见');
    expect(find.byKey(coverSwipeKey), findsOneWidget);
    expect(find.byTooltip('歌词'), findsNothing, reason: '平板上没有翻页按钮');
    expect(tester.takeException(), isNull);
  });

  // ---------- 手机横屏：左封面 / 右控制区 ----------

  testWidgets('平板：切歌 / 音量手势仍然只认封面那张图', (tester) async {
    _useTabletWindow(tester);
    final harness = _PlayerHarness()..volumeRead = 0.5;
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      harness.build(
        loadLyrics: (_) async => fakeLyrics(<(int, String)>[(5_000, '第一句')]),
      ),
    );
    await tester.pumpAndSettle();

    // 封面上：左右滑切歌、上下滑调音量，与手机上同一套。
    await tester.fling(find.byKey(coverSwipeKey), const Offset(-200, 0), 1000);
    await tester.pumpAndSettle();
    expect(harness.calls, ['next']);
    expect(find.text('下一曲'), findsOneWidget, reason: '提示还是闪在封面上');

    final up = await _startVolumeDrag(tester, 60);
    await up.up();
    await tester.pumpAndSettle();
    expect(harness.volumeSets.single, 0.6875, reason: '0.5 + 60/320');

    // 歌词那一栏上划一下：不该切歌（它只管滚歌词）。
    await tester.fling(find.byType(LyricsView), const Offset(-200, 0), 1000);
    await tester.pumpAndSettle();
    expect(harness.calls, ['next'], reason: '歌词栏上的滑动不切歌');
    expect(tester.takeException(), isNull);
  });

  testWidgets('手机横屏：左边封面、右边控制，歌词靠封面左上角那颗按钮换出来', (tester) async {
    _useLandscapePhoneWindow(tester);
    final harness = _PlayerHarness();
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      harness.build(
        loadLyrics: (_) async => fakeLyrics(<(int, String)>[(5_000, '第一句')]),
      ),
    );
    await tester.pumpAndSettle();

    // 默认：左边封面、右边控制，歌词还没出来。
    expect(find.byKey(coverSwipeKey), findsOneWidget);
    expect(find.byType(LyricsView), findsNothing);
    final cover = tester.getRect(find.byKey(coverSwipeKey));
    expect(
      tester.getRect(find.byType(Slider)).left,
      greaterThanOrEqualTo(cover.right),
      reason: '控制区整条都在封面右边',
    );
    // 「歌词」按钮在封面的左上角。
    final button = tester.getCenter(find.byTooltip('歌词'));
    expect(button.dx, lessThan(cover.center.dx));
    expect(button.dy, lessThan(cover.center.dy));

    // 点它：左边那一栏换成歌词，右边照旧是控制区——看歌词时也能切歌。
    await tester.tap(find.byTooltip('歌词'));
    await tester.pumpAndSettle();
    expect(find.byType(LyricsView), findsOneWidget);
    expect(find.text('第一句'), findsOneWidget);
    expect(find.byKey(coverSwipeKey), findsNothing, reason: '封面让位给歌词');
    // 「回封面」在歌词那一栏的左上角：它原来靠右摆，横屏时正好贴着两列的交界，
    // 得跨过大半个屏幕去点。
    final pane = tester.getRect(find.byType(LyricsView));
    final back = tester.getRect(find.byTooltip('回封面（右滑也可以）'));
    expect(back.center.dx, lessThan(pane.center.dx), reason: '按钮在左栏的左边');
    expect(back.center.dy, lessThan(pane.center.dy), reason: '在顶上一行');
    await tester.tap(find.byTooltip('下一首'));
    expect(harness.calls, ['next'], reason: '右边还是控制区，点得到');

    // 歌词里那颗「回封面」把它换回来。
    await tester.tap(find.byTooltip('回封面（右滑也可以）'));
    await tester.pumpAndSettle();
    expect(find.byKey(coverSwipeKey), findsOneWidget);
    expect(find.byType(LyricsView), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('手机横屏：封面上的切歌 / 音量手势照旧', (tester) async {
    _useLandscapePhoneWindow(tester);
    final harness = _PlayerHarness()..volumeRead = 0.5;
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.build());
    await tester.pumpAndSettle();

    await tester.fling(find.byKey(coverSwipeKey), const Offset(-200, 0), 1000);
    await tester.pumpAndSettle();
    expect(harness.calls, ['next']);

    final up = await _startVolumeDrag(tester, 60);
    await up.up();
    await tester.pumpAndSettle();
    expect(harness.volumeSets.single, 0.6875, reason: '0.5 + 60/320');
    expect(tester.takeException(), isNull);
  });
}
