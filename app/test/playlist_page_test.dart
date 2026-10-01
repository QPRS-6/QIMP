import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/src/playlist_api.dart';
import 'package:musicplayer/src/playlist_page.dart';
import 'package:musicplayer/src/queue_store.dart';
import 'package:musicplayer/src/rust/api/library.dart';
import 'package:musicplayer/src/rust/api/player.dart';

import 'fixtures.dart';

/// 只实现页面用到的那几个方法：宿主机上打不了 FFI。
class FakeApi extends PlaylistApi {
  FakeApi(this.tracks_);

  List<Track> tracks_;

  final List<String> calls = [];

  @override
  List<Track> tracks(int playlistId) {
    if (playlistId != 1) throw StateError('没有这个列表');
    return tracks_;
  }

  @override
  bool remove(int playlistId, int trackId) {
    calls.add('remove:$playlistId:$trackId');
    tracks_ = tracks_.where((t) => t.id != trackId).toList();
    return true;
  }
}

Playlist playlist({int id = 1, String name = '学习'}) =>
    Playlist(id: id, name: name, trackCount: 2, createdAt: 0);

Future<void> pumpPage(
  WidgetTester tester,
  FakeApi api, {
  Playlist? list,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: PlaylistPage(
        playlist: list ?? playlist(),
        player: ValueNotifier<PlayerSnapshot?>(null),
        queue: PlayQueueStore(),
        api: api,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('列出列表里的歌', (tester) async {
    await pumpPage(
      tester,
      FakeApi([
        fakeTrack(id: 1, title: '第一首'),
        fakeTrack(id: 2, title: '第二首'),
      ]),
    );

    expect(find.text('学习'), findsOneWidget);
    expect(find.text('第一首'), findsOneWidget);
    expect(find.text('第二首'), findsOneWidget);
  });

  testWidgets('空列表给出「怎么加歌」的提示', (tester) async {
    await pumpPage(tester, FakeApi([]));

    expect(find.textContaining('添加到播放列表'), findsOneWidget);
  });

  testWidgets('编辑模式下按 ✕ 把歌移出列表（按 id，不是按行号）', (tester) async {
    final api = FakeApi([
      fakeTrack(id: 1, title: '第一首'),
      fakeTrack(id: 2, title: '第二首'),
    ]);
    await pumpPage(tester, api);

    // 非编辑模式：没有移出按钮，点一行是播放（这里不点，播放要 FFI）。
    expect(find.byTooltip('移出列表'), findsNothing);

    await tester.tap(find.byTooltip('编辑（把歌移出列表）'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('移出列表'), findsNWidgets(2));

    await tester.tap(find.byTooltip('移出列表').at(1));
    await tester.pumpAndSettle();

    expect(api.calls, ['remove:1:2']);
    expect(find.text('第二首'), findsNothing);
    expect(find.text('第一首'), findsOneWidget);
  });

  testWidgets('读不出列表时不崩，给一条错误提示', (tester) async {
    await pumpPage(tester, FakeApi([]), list: playlist(id: 2));

    expect(find.textContaining('列表读不出来'), findsOneWidget);
  });
}
