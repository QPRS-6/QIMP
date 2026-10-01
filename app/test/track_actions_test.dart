// 长按曲目的动作表。
//
// 「从库中删除」与「从储存中删除」只差两个字，后果却差一个文件，所以这里重点钉住
// 两件事：前者只清标记、后者必须先确认；以及界面能拿到「删了哪些」的信号
// ——正在放的那一首被删掉时得把播放停掉。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/src/library_api.dart';
import 'package:musicplayer/src/playlist_api.dart';
import 'package:musicplayer/src/rust/api/library.dart';
import 'package:musicplayer/src/track_actions.dart';

import 'fixtures.dart';

/// 只实现动作表用到的三个方法。
class FakeLibraryApi extends LibraryApi {
  final List<List<int>> removed = [];
  final List<List<int>> deleted = [];

  /// 下一次「从储存中删除」的结果。
  DeleteSummary result = const DeleteSummary(deleted: 1, failed: <String>[]);

  @override
  int remove(List<int> trackIds) {
    removed.add(trackIds);
    return trackIds.length;
  }

  @override
  Future<DeleteSummary> deleteFiles(List<int> trackIds) async {
    deleted.add(trackIds);
    return result;
  }
}

class FakePlaylistApi extends PlaylistApi {
  final List<Playlist> lists = <Playlist>[];

  @override
  List<Playlist> list() => List<Playlist>.unmodifiable(lists);
}

/// 摆一个按钮：点它就等于长按了那一首歌。结果记进 `results`。
Future<void> pumpHost(
  WidgetTester tester, {
  required FakeLibraryApi api,
  List<TrackActionResult>? results,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () async {
                final result = await showTrackActions(
                  context,
                  track: fakeTrack(id: 9, title: '要处理的歌'),
                  libraryApi: api,
                  playlistApi: FakePlaylistApi(),
                );
                results?.add(result);
              },
              child: const Text('长按'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('长按'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('三件事一次摆出来：加入播放列表 / 从库中删除 / 从储存中删除', (tester) async {
    await pumpHost(tester, api: FakeLibraryApi());

    expect(find.text('要处理的歌'), findsOneWidget);
    expect(find.text('添加到播放列表'), findsOneWidget);
    expect(find.text('从库中删除'), findsOneWidget);
    expect(find.text('从储存中删除'), findsOneWidget);
    expect(
      find.text('只是不在曲库里显示，文件还在'),
      findsOneWidget,
      reason: '两者差别要写在脸上',
    );
  });

  testWidgets('从库中删除：只清标记，文件不动', (tester) async {
    final api = FakeLibraryApi();
    final results = <TrackActionResult>[];
    await pumpHost(tester, api: api, results: results);

    await tester.tap(find.text('从库中删除'));
    await tester.pumpAndSettle();

    expect(api.removed, [
      <int>[9],
    ]);
    expect(api.deleted, isEmpty, reason: '这一项不该碰文件');
    expect(find.text('已从曲库移出，文件还在'), findsOneWidget);
    expect(results.single.changed, isTrue, reason: '曲库变了，界面要重读');
    expect(results.single.deletedIds, isEmpty);
  });

  testWidgets('从储存中删除：先问一句，点取消就什么都不做', (tester) async {
    final api = FakeLibraryApi();
    final results = <TrackActionResult>[];
    await pumpHost(tester, api: api, results: results);

    await tester.tap(find.text('从储存中删除'));
    await tester.pumpAndSettle();
    expect(find.text('从储存中删除 1 个文件？'), findsOneWidget);
    expect(find.textContaining('不能恢复'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(api.deleted, isEmpty);
    expect(results.single.changed, isFalse);
  });

  testWidgets('确认之后才真删，并把删掉的 id 交回界面（正在放的那首要停）', (tester) async {
    final api = FakeLibraryApi();
    final results = <TrackActionResult>[];
    await pumpHost(tester, api: api, results: results);

    await tester.tap(find.text('从储存中删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(api.deleted, [
      <int>[9],
    ]);
    expect(find.textContaining('已删除 1 个文件'), findsOneWidget);
    expect(results.single.changed, isTrue);
    expect(results.single.deletedIds, <int>[9]);
  });

  testWidgets('有文件删不掉时照实说，不假装全删干净了', (tester) async {
    final api = FakeLibraryApi()
      ..result = const DeleteSummary(deleted: 1, failed: <String>['/m/b.mp3：权限不足']);
    await pumpHost(tester, api: api);

    await tester.tap(find.text('从储存中删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.textContaining('1 个没删掉'), findsOneWidget);
  });

  testWidgets('划掉面板＝什么都没发生', (tester) async {
    final api = FakeLibraryApi();
    final results = <TrackActionResult>[];
    await pumpHost(tester, api: api, results: results);

    // 点遮罩关闭面板。
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(api.removed, isEmpty);
    expect(api.deleted, isEmpty);
    expect(results.single.changed, isFalse);
  });
}
