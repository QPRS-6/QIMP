// 「＋ 添加歌曲」面板的用例。
//
// 曲库是用户自己挑出来的：扫到的歌不会自动入库，这个面板就是唯一的入口
// ——所以「能挑、能反悔、能一把全收、没东西时说得清」四件事都要钉住。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/src/add_songs.dart';
import 'package:musicplayer/src/library_api.dart';
import 'package:musicplayer/src/rust/api/library.dart';

import 'fixtures.dart';

/// 只实现这个面板用到的那几个方法：待入库列表与「收进曲库」。
class FakeLibraryApi extends LibraryApi {
  FakeLibraryApi(this.candidates);

  final List<Track> candidates;

  /// 每一次「加入曲库」收到的 id（顺序也记下来：界面按勾选顺序给）。
  final List<List<int>> addCalls = [];

  @override
  List<Track> pending({int limit = 2000}) => List<Track>.unmodifiable(candidates);

  @override
  int add(List<int> trackIds) {
    addCalls.add(trackIds);
    return trackIds.length;
  }
}

/// 摆一个按钮：点它就等于在主页上点「＋」。
///
/// `results` 收的是 `showAddSongs` 的返回值——主页正是靠它决定要不要刷新列表。
Future<void> pumpHost(
  WidgetTester tester,
  FakeLibraryApi api, {
  List<int>? results,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () async {
                final added = await showAddSongs(context, api: api);
                results?.add(added);
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

/// 面板底部那个「加入曲库（n）」按钮。
FilledButton submitButton(WidgetTester tester, int count) =>
    tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '加入曲库（$count）'),
    );

void main() {
  testWidgets('列出待入库的歌，勾两首就加这两首', (tester) async {
    final api = FakeLibraryApi(<Track>[
      fakeTrack(id: 1, title: '第一首'),
      fakeTrack(id: 2, title: '第二首'),
      fakeTrack(id: 3, title: '第三首'),
    ]);
    final results = <int>[];
    await pumpHost(tester, api, results: results);

    expect(find.text('添加歌曲'), findsOneWidget);
    expect(find.text('扫描到 3 首还没进曲库'), findsOneWidget);
    expect(find.text('选几首加进来'), findsOneWidget);
    expect(find.byType(CheckboxListTile), findsNWidgets(3));

    await tester.tap(find.text('第一首'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第二首'));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 首'), findsOneWidget);

    await tester.tap(find.text('加入曲库（2）'));
    await tester.pumpAndSettle();

    expect(api.addCalls, [
      <int>[1, 2],
    ]);
    expect(results, <int>[2], reason: '返回加进去的条数，界面据此刷新');
    expect(find.text('已加入曲库 2 首'), findsOneWidget, reason: '面板关掉后要有回执');
    expect(find.text('第一首'), findsNothing, reason: '加完把面板收掉');
  });

  testWidgets('一首都没勾时按钮是灰的：不能“加了 0 首”', (tester) async {
    final api = FakeLibraryApi(<Track>[fakeTrack(id: 1, title: '第一首')]);
    await pumpHost(tester, api);

    expect(submitButton(tester, 0).onPressed, isNull);

    // 勾上再取消，仍然要回到灰的状态。
    await tester.tap(find.text('第一首'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第一首'));
    await tester.pumpAndSettle();
    expect(find.text('选几首加进来'), findsOneWidget);
    expect(submitButton(tester, 0).onPressed, isNull);
  });

  testWidgets('全选一把收进来：刚装好第一次扫完就是这条路径', (tester) async {
    final api = FakeLibraryApi(<Track>[
      fakeTrack(id: 1, title: '第一首'),
      fakeTrack(id: 2, title: '第二首'),
    ]);
    await pumpHost(tester, api);

    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 首'), findsOneWidget);
    expect(find.text('取消全选'), findsOneWidget);

    // 再点一下是取消全选，不该把歌加进去。
    await tester.tap(find.text('取消全选'));
    await tester.pumpAndSettle();
    expect(find.text('选几首加进来'), findsOneWidget);

    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入曲库（2）'));
    await tester.pumpAndSettle();
    expect(api.addCalls, [
      <int>[1, 2],
    ]);
  });

  testWidgets('没有待入库的歌时直接说清楚，不弹一个空面板', (tester) async {
    final api = FakeLibraryApi(const <Track>[]);
    await pumpHost(tester, api);

    expect(find.text('添加歌曲'), findsNothing);
    expect(find.textContaining('没有待入库的歌'), findsOneWidget);
    expect(api.addCalls, isEmpty);
  });
}
