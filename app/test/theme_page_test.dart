import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/src/theme_page.dart';
import 'package:musicplayer/src/theme_settings.dart';

/// 内存版落盘入口（与 `theme_settings_test.dart` 里那份同一个套路）。
class FakeStore extends ThemeStore {
  final List<Color?> writes = <Color?>[];

  @override
  Future<Color?> load() async => null;

  @override
  Future<void> save(Color? color) async => writes.add(color);
}

/// 把设置和界面接起来的那一层，跟真机上 `main.dart` 的做法一样：
/// 主题从设置算出来，设置一变整棵树重建。
Widget harness(ThemeSettings settings) => AnimatedBuilder(
  animation: settings,
  builder: (context, _) =>
      MaterialApp(theme: settings.theme, home: ThemePage(settings: settings)),
);

/// 编辑页此刻真正的页面底色（不是「设置里记着什么」，是界面上生效的那个）。
Color pageColor(WidgetTester tester) =>
    Theme.of(tester.element(find.byType(ThemePage))).scaffoldBackgroundColor;

void main() {
  testWidgets('打开时停在当前底色上：预设都在，滑块三路', (tester) async {
    final settings = ThemeSettings(
      store: FakeStore(),
      background: const Color(0xFF0E1B2A),
    );
    await tester.pumpWidget(harness(settings));

    expect(find.text('编辑主题'), findsOneWidget);
    expect(find.textContaining('当前：#0E1B2A'), findsOneWidget);
    expect(find.byType(Slider), findsNWidgets(3));
    for (final (name, _) in kBackgroundPresets) {
      expect(find.byTooltip(name), findsOneWidget, reason: '预设「$name」不在');
    }
  });

  testWidgets('点一个预设：立刻生效、写一次盘、对勾换过去', (tester) async {
    final store = FakeStore();
    final settings = ThemeSettings(store: store);
    await tester.pumpWidget(harness(settings));
    expect(pageColor(tester), defaultAppTheme().colorScheme.surface);

    await tester.tap(find.byTooltip('纯黑'));
    await tester.pumpAndSettle();

    expect(settings.background, const Color(0xFF000000));
    expect(store.writes, [const Color(0xFF000000)]);
    expect(pageColor(tester), const Color(0xFF000000), reason: '这一页自己就换底了');
    expect(find.textContaining('当前：#000000'), findsOneWidget);
    // 深底上文字转成浅色，不然就成了黑底黑字。
    expect(
      Theme.of(tester.element(find.byType(ThemePage)))
          .colorScheme
          .onSurface
          .computeLuminance(),
      greaterThan(0.7),
    );
  });

  testWidgets('拖滑块：界面跟着走，松手才写一次盘', (tester) async {
    final store = FakeStore();
    final settings = ThemeSettings(store: store);
    await tester.pumpWidget(harness(settings));

    // 从「默认」起步：滑块要有东西可拖，先给它出厂主题那个底色。
    await tester.drag(find.byType(Slider).first, const Offset(-80, 0));
    await tester.pumpAndSettle();

    expect(settings.background, isNotNull, reason: '拖完就是自定义色了');
    expect(pageColor(tester), settings.background);
    expect(store.writes.length, 1, reason: '一趟拖动只写一次（松手那一下）');
    expect(find.textContaining('当前：#'), findsOneWidget);
  });

  testWidgets('「恢复默认」把底色清掉，按钮自己就灰了', (tester) async {
    final store = FakeStore();
    final settings = ThemeSettings(
      store: store,
      background: const Color(0xFF000000),
    );
    await tester.pumpWidget(harness(settings));

    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();

    expect(settings.background, isNull);
    expect(store.writes, [null]);
    expect(pageColor(tester), defaultAppTheme().colorScheme.surface);
    expect(
      tester.widget<TextButton>(find.widgetWithText(TextButton, '恢复默认'))
          .onPressed,
      isNull,
      reason: '已经是默认了，再点没有意义',
    );
  });

  testWidgets('主页右上角那颗调色板点得开编辑页', (tester) async {
    final settings = ThemeSettings(store: FakeStore());
    await tester.pumpWidget(
      MaterialApp(
        theme: settings.theme,
        // 只搭一条顶栏：真机的主页要先过存储权限、开数据库、连引擎，
        // 那些跟这颗按钮没关系。
        home: Scaffold(
          appBar: AppBar(
            title: const Text('本地音乐播放器'),
            actions: [ThemeButton(settings: settings)],
          ),
        ),
      ),
    );

    expect(find.byTooltip('编辑主题'), findsOneWidget);
    await tester.tap(find.byTooltip('编辑主题'));
    await tester.pumpAndSettle();
    expect(find.byType(ThemePage), findsOneWidget);
  });
}
