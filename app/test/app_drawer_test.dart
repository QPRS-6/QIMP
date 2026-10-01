import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/src/app_drawer.dart';
import 'package:musicplayer/src/playlist_api.dart';
import 'package:musicplayer/src/rust/api/library.dart';

/// 内存版播放列表：宿主机上没有 `.so`，抽屉必须能在「换成桩」的前提下整条跑通。
class FakePlaylistApi extends PlaylistApi {
  FakePlaylistApi([List<Playlist>? initial])
    : lists = List<Playlist>.of(initial ?? const <Playlist>[]);

  final List<Playlist> lists;

  /// 记下调用，断言「界面到底做了什么」。
  final List<String> calls = [];

  bool fail = false;

  int _nextId = 100;

  void _guard() {
    if (fail) throw StateError('曲库没打开');
  }

  @override
  List<Playlist> list() {
    _guard();
    return List<Playlist>.unmodifiable(lists);
  }

  @override
  int create(String name) {
    _guard();
    calls.add('create:$name');
    final id = _nextId++;
    lists.add(Playlist(id: id, name: name, trackCount: 0, createdAt: 0));
    return id;
  }

  @override
  void rename(int playlistId, String name) {
    _guard();
    calls.add('rename:$playlistId:$name');
    final index = lists.indexWhere((p) => p.id == playlistId);
    final old = lists[index];
    lists[index] = Playlist(
      id: old.id,
      name: name,
      trackCount: old.trackCount,
      createdAt: old.createdAt,
    );
  }

  @override
  void delete(int playlistId) {
    _guard();
    calls.add('delete:$playlistId');
    lists.removeWhere((p) => p.id == playlistId);
  }
}

Playlist playlist({int id = 1, String name = '学习', int trackCount = 0}) =>
    Playlist(id: id, name: name, trackCount: trackCount, createdAt: 0);

/// 抽屉本体是个普通 widget（`Drawer` 只是 Material 容器），所以可以直接摆进
/// 一个 Scaffold 的 body 里测，不用先「打开抽屉」。
Future<void> pumpDrawer(
  WidgetTester tester, {
  required PlaylistApi api,
  HomeView view = HomeView.library,
  int? playlistId,
  ValueChanged<HomeView>? onSelectView,
  ValueChanged<Playlist>? onSelectPlaylist,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 320,
          child: AppDrawer(
            view: view,
            onSelectView: onSelectView ?? (_) {},
            playlistId: playlistId,
            onSelectPlaylist: onSelectPlaylist ?? (_) {},
            api: api,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('只有导航三项 + 播放列表，没有音效 / 书签 / 我的最爱', (tester) async {
    await pumpDrawer(tester, api: FakePlaylistApi());

    expect(find.text('主页'), findsOneWidget);
    expect(find.text('我的音乐'), findsOneWidget);
    expect(find.text('队列'), findsOneWidget);
    expect(find.text('音效'), findsNothing);
    expect(find.text('书签'), findsNothing);
    expect(find.text('我的最爱'), findsNothing);
  });

  testWidgets('列出播放列表与歌曲数', (tester) async {
    await pumpDrawer(
      tester,
      api: FakePlaylistApi([
        playlist(id: 1, name: '学习', trackCount: 12),
        playlist(id: 2, name: '通勤'),
      ]),
    );

    expect(find.text('学习'), findsOneWidget);
    expect(find.text('12 首'), findsOneWidget);
    expect(find.text('通勤'), findsOneWidget);
    expect(find.text('0 首'), findsOneWidget);
  });

  testWidgets('导航项把选择回调传出去', (tester) async {
    HomeView? picked;
    await pumpDrawer(
      tester,
      api: FakePlaylistApi(),
      onSelectView: (view) => picked = view,
    );

    await tester.tap(find.text('队列'));
    await tester.pumpAndSettle();

    expect(picked, HomeView.queue);
  });

  testWidgets('点列表打开它', (tester) async {
    Playlist? opened;
    await pumpDrawer(
      tester,
      api: FakePlaylistApi([playlist(id: 7, name: '夜跑', trackCount: 3)]),
      onSelectPlaylist: (p) => opened = p,
    );

    await tester.tap(find.text('夜跑'));
    await tester.pumpAndSettle();

    expect(opened?.id, 7);
  });

  testWidgets('读不出播放列表时给一行提示而不是崩', (tester) async {
    final api = FakePlaylistApi()..fail = true;
    await pumpDrawer(tester, api: api);

    expect(find.textContaining('播放列表读不出来'), findsOneWidget);
    // 导航照样能用
    expect(find.text('主页'), findsOneWidget);
  });

  testWidgets('空列表点 ✕ 直接删，不弹确认', (tester) async {
    final api = FakePlaylistApi([playlist(id: 1, name: '空的')]);
    await pumpDrawer(tester, api: api);

    await tester.tap(find.byTooltip('删除「空的」'));
    await tester.pumpAndSettle();

    expect(api.calls, ['delete:1']);
    expect(find.text('空的'), findsNothing);
  });

  testWidgets('非空列表删除前要确认，取消则不动', (tester) async {
    final api = FakePlaylistApi([playlist(id: 1, name: '学习', trackCount: 9)]);
    await pumpDrawer(tester, api: api);

    await tester.tap(find.byTooltip('删除「学习」'));
    await tester.pumpAndSettle();
    expect(find.text('删除「学习」？'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(api.calls, isEmpty);
    expect(find.text('学习'), findsOneWidget);

    await tester.tap(find.byTooltip('删除「学习」'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(api.calls, ['delete:1']);
  });

  testWidgets('＋ 新建列表（空名字不给过）', (tester) async {
    final api = FakePlaylistApi();
    await pumpDrawer(tester, api: api);

    await tester.tap(find.byTooltip('新建播放列表'));
    await tester.pumpAndSettle();

    // 先试空名字：按约定等于「取消」，什么都不该发生。
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(api.calls, isEmpty);
    expect(find.text('新建播放列表'), findsNothing, reason: '空名字等于取消');

    await tester.tap(find.byTooltip('新建播放列表'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '通勤');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    expect(api.calls, ['create:通勤']);
    expect(find.text('通勤'), findsOneWidget);
  });

  testWidgets('✎ 进编辑模式后，点一行是改名', (tester) async {
    final api = FakePlaylistApi([playlist(id: 3, name: '旧名字')]);
    await pumpDrawer(tester, api: api);

    await tester.tap(find.byTooltip('编辑（改名 / 删除）'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('旧名字'));
    await tester.pumpAndSettle();
    expect(find.text('重命名'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '新名字');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(api.calls, ['rename:3:新名字']);
    expect(find.text('新名字'), findsOneWidget);
  });
}
