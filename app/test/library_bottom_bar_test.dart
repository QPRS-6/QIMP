// 主页最底下那条工具条的用例。
//
// 它同时承担两件事：用户看到的曲库统计，以及「多选 / 添加歌曲 / 更多」三个入口。
// 参考图给的就是这一条，所以在宿主机上把它钉住：真机上要滚到列表底部才看得见。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/src/library_bottom_bar.dart';
import 'package:musicplayer/src/rust/api/library.dart';

/// 452 首 / 27:27:36 / 10 GiB —— 与参考图上那行同一个形状。
Stats fakeStats() => const Stats(
  trackCount: 452,
  albumCount: 30,
  artistCount: 40,
  playlistCount: 2,
  totalDurationMs: 98856000,
  totalSizeBytes: 10737418240,
);

/// 按 tooltip 找按钮：这一条上的按钮只有 tooltip 能认（图标都是通用字形）。
IconButton buttonWithTooltip(WidgetTester tester, String tooltip) => tester
    .widgetList<IconButton>(find.byType(IconButton))
    .firstWhere((button) => button.tooltip == tooltip);

Widget harness({
  Stats? stats,
  bool selecting = false,
  int selectedCount = 0,
  int totalCount = 3,
  VoidCallback? onToggleSelect,
  VoidCallback? onAddSongs,
  VoidCallback? onScanIncremental,
  VoidCallback? onScanFull,
  VoidCallback? onSelectAll,
  VoidCallback? onRemoveFromLibrary,
  VoidCallback? onDeleteFromStorage,
}) => MaterialApp(
  home: Scaffold(
    bottomNavigationBar: LibraryBottomBar(
      stats: stats,
      selecting: selecting,
      selectedCount: selectedCount,
      totalCount: totalCount,
      onToggleSelect: onToggleSelect ?? () {},
      onAddSongs: onAddSongs ?? () {},
      onScanIncremental: onScanIncremental ?? () {},
      onScanFull: onScanFull ?? () {},
      onSelectAll: onSelectAll ?? () {},
      onRemoveFromLibrary: onRemoveFromLibrary ?? () {},
      onDeleteFromStorage: onDeleteFromStorage ?? () {},
    ),
  ),
);

void main() {
  testWidgets('三个入口都在，统计按参考图的三个数字排', (tester) async {
    var toggled = 0;
    var added = 0;
    await tester.pumpWidget(
      harness(
        stats: fakeStats(),
        onToggleSelect: () => toggled += 1,
        onAddSongs: () => added += 1,
      ),
    );

    expect(find.byTooltip('多选'), findsOneWidget);
    expect(find.byTooltip('添加歌曲（从扫描到的文件里挑）'), findsOneWidget);
    expect(find.byTooltip('更多'), findsOneWidget);
    expect(find.text('452 / 27:27:36 / 10.0 GB'), findsOneWidget);

    await tester.tap(find.byTooltip('多选'));
    await tester.tap(find.byTooltip('添加歌曲（从扫描到的文件里挑）'));
    await tester.pump();
    expect(toggled, 1);
    expect(added, 1);
  });

  testWidgets('参考图里的列表 / 搜索图标不要：搜索框在顶上那一栏', (tester) async {
    await tester.pumpWidget(harness(stats: fakeStats()));

    // 参考图那一排是五个图标，这里只留 1（多选）、3（添加歌曲）、5（更多）：
    // 第二个（列表）与第四个（搜索）都不要，搜索框留在顶上那一栏不动。
    final tooltips = tester
        .widgetList<IconButton>(find.byType(IconButton))
        .map((button) => button.tooltip)
        .toList();
    expect(tooltips, <String>['多选', '添加歌曲（从扫描到的文件里挑）', '更多']);
    expect(find.byIcon(Icons.search), findsNothing);
    expect(find.byIcon(Icons.list), findsNothing);
  });

  testWidgets('「更多」里就是原来顶栏那两个扫描项', (tester) async {
    var incremental = 0;
    var full = 0;
    await tester.pumpWidget(
      harness(
        stats: fakeStats(),
        onScanIncremental: () => incremental += 1,
        onScanFull: () => full += 1,
      ),
    );

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('增量扫描'), findsOneWidget);
    expect(find.text('全量扫描'), findsOneWidget);

    await tester.tap(find.text('增量扫描'));
    await tester.pumpAndSettle();
    expect(incremental, 1);
    expect(full, 0);

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全量扫描'));
    await tester.pumpAndSettle();
    expect(full, 1);
  });

  testWidgets('多选模式：没勾东西时两个删除动作是灰的', (tester) async {
    var removed = 0;
    var deleted = 0;
    await tester.pumpWidget(
      harness(
        stats: fakeStats(),
        selecting: true,
        selectedCount: 0,
        totalCount: 3,
        onRemoveFromLibrary: () => removed += 1,
        onDeleteFromStorage: () => deleted += 1,
      ),
    );

    expect(find.text('已选 0 首'), findsOneWidget);
    expect(
      buttonWithTooltip(tester, '从库中删除').onPressed,
      isNull,
      reason: '一首都没选，点了也不知道删谁',
    );
    expect(buttonWithTooltip(tester, '从储存中删除').onPressed, isNull);
    expect(removed, 0);
    expect(deleted, 0);
  });

  testWidgets('多选模式：勾上之后两个删除动作都能点', (tester) async {
    var removed = 0;
    var deleted = 0;
    await tester.pumpWidget(
      harness(
        stats: fakeStats(),
        selecting: true,
        selectedCount: 2,
        totalCount: 3,
        onRemoveFromLibrary: () => removed += 1,
        onDeleteFromStorage: () => deleted += 1,
      ),
    );

    expect(find.text('已选 2 首'), findsOneWidget);
    await tester.tap(find.byTooltip('从库中删除'));
    await tester.tap(find.byTooltip('从储存中删除'));
    await tester.pump();
    expect(removed, 1);
    expect(deleted, 1);
  });

  testWidgets('全选 / 取消全选是同一个按钮，选满了就换说法', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      harness(
        stats: fakeStats(),
        selecting: true,
        selectedCount: 1,
        totalCount: 3,
        onSelectAll: () => calls += 1,
      ),
    );
    expect(find.text('全选'), findsOneWidget);

    await tester.pumpWidget(
      harness(
        stats: fakeStats(),
        selecting: true,
        selectedCount: 3,
        totalCount: 3,
        onSelectAll: () => calls += 1,
      ),
    );
    expect(find.text('取消全选'), findsOneWidget);

    await tester.tap(find.text('取消全选'));
    await tester.pump();
    expect(calls, 1);
  });

  testWidgets('统计还没读出来时说「正在读取曲库…」，别先摆一行 0', (tester) async {
    await tester.pumpWidget(harness());
    expect(find.text('正在读取曲库…'), findsOneWidget);
  });
}
