import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/src/add_to_playlist.dart';
import 'package:musicplayer/src/playlist_api.dart';
import 'package:musicplayer/src/rust/api/library.dart';

import 'fixtures.dart';

class FakeApi extends PlaylistApi {
  FakeApi([List<Playlist>? initial])
    : lists = List<Playlist>.of(initial ?? const <Playlist>[]);

  final List<Playlist> lists;
  final List<String> calls = [];
  int _nextId = 50;

  @override
  List<Playlist> list() => List<Playlist>.unmodifiable(lists);

  @override
  int create(String name) {
    calls.add('create:$name');
    final id = _nextId++;
    lists.add(Playlist(id: id, name: name, trackCount: 0, createdAt: 0));
    return id;
  }

  @override
  bool add(int playlistId, int trackId) {
    calls.add('add:$playlistId:$trackId');
    return !alreadyThere;
  }

  /// 用来验「已经在列表里」的那条提示。
  bool alreadyThere = false;
}

Playlist playlist({int id = 1, String name = '学习', int trackCount = 0}) =>
    Playlist(id: id, name: name, trackCount: trackCount, createdAt: 0);

/// 造一个带按钮的页面：点按钮就等于「长按曲目」。
Future<void> pumpHost(WidgetTester tester, FakeApi api) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () =>
                  showAddToPlaylist(context, track: fakeTrack(id: 9), api: api),
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

void main() {
  testWidgets('选一个已有列表就把歌加进去', (tester) async {
    final api = FakeApi([playlist(id: 1, name: '学习')]);
    await pumpHost(tester, api);

    expect(find.text('添加到播放列表'), findsOneWidget);
    await tester.tap(find.text('学习'));
    await tester.pumpAndSettle();

    expect(api.calls, ['add:1:9']);
    expect(find.text('已加入「学习」'), findsOneWidget);
  });

  testWidgets('已经在列表里时说清楚，而不是假装加上了', (tester) async {
    final api = FakeApi([playlist(id: 1, name: '学习')])..alreadyThere = true;
    await pumpHost(tester, api);

    await tester.tap(find.text('学习'));
    await tester.pumpAndSettle();

    expect(find.text('「学习」里已经有了'), findsOneWidget);
  });

  testWidgets('面板里能新建列表并直接加入', (tester) async {
    final api = FakeApi();
    await pumpHost(tester, api);

    await tester.tap(find.text('新建播放列表…'));
    await tester.pumpAndSettle();

    // 名字空着时按钮不生效（还在这一屏）
    await tester.tap(find.text('创建并加入'));
    await tester.pumpAndSettle();
    expect(api.calls, isEmpty);

    await tester.enterText(find.byType(TextField), '夜跑');
    await tester.tap(find.text('创建并加入'));
    await tester.pumpAndSettle();

    expect(api.calls, ['create:夜跑', 'add:50:9']);
    expect(find.text('已加入「夜跑」'), findsOneWidget);
  });
}
