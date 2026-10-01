import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/src/app_drawer.dart';
import 'package:musicplayer/src/playlist_api.dart';
import 'package:musicplayer/src/playlist_files.dart';
import 'package:musicplayer/src/rust/api/library.dart';

/// 内存版播放列表：宿主机上没有 `.so`，抽屉必须能在「换成桩」的前提下整条跑通。
class FakePlaylistApi extends PlaylistApi {
  FakePlaylistApi([List<Playlist>? initial])
    : lists = List<Playlist>.of(initial ?? const <Playlist>[]);

  final List<Playlist> lists;

  /// 记下调用，断言「界面到底做了什么」。
  final List<String> calls = [];

  /// 导入 / 导出的调用（与 `calls` 分开记，断言时看得更清楚）。
  final List<String> fileCalls = [];

  /// 下一次导入返回什么；不设就给一个「两首全进去了」的结果。
  PlaylistImport? importResult;

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

  @override
  Future<PlaylistImport> importFile({
    required String fileName,
    required Uint8List bytes,
  }) async {
    _guard();
    fileCalls.add('import:$fileName:${utf8.decode(bytes)}');
    final result =
        importResult ??
        const PlaylistImport(
          playlistId: 200,
          added: 2,
          missing: 0,
          missingPaths: <String>[],
          skipped: 0,
        );
    lists.add(
      Playlist(
        id: result.playlistId,
        name: '导入的列表',
        trackCount: result.added,
        createdAt: 0,
      ),
    );
    return result;
  }

  @override
  String exportText({
    required int playlistId,
    required PlaylistExportFormat format,
  }) {
    _guard();
    fileCalls.add('export:$playlistId:${format.extension}');
    return '#EXTM3U\n';
  }
}

/// 平台文件通道的桩：记下 pick / save，并按需要返回「挑中的文件」。
class FakeFiles extends PlaylistFiles {
  FakeFiles({this.picked});

  final PickedPlaylistFile? picked;

  final List<String> calls = [];

  bool fail = false;

  @override
  Future<PickedPlaylistFile?> pick() async {
    calls.add('pick');
    if (fail) throw StateError('打不开文件选择器');
    return picked;
  }

  @override
  Future<String?> save({required String name, required String text}) async {
    calls.add('save:$name:${text.length}');
    if (fail) throw StateError('写不进去');
    return name;
  }
}

Playlist playlist({int id = 1, String name = '学习', int trackCount = 0}) =>
    Playlist(id: id, name: name, trackCount: trackCount, createdAt: 0);

/// 抽屉本体是个普通 widget（`Drawer` 只是 Material 容器），所以可以直接摆进
/// 一个 Scaffold 的 body 里测，不用先「打开抽屉」。
Future<void> pumpDrawer(
  WidgetTester tester, {
  required PlaylistApi api,
  PlaylistFiles files = const PlaylistFiles(),
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
            files: files,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 打开某一行的「更多」菜单（点右边的 ⋮）。
Future<void> openMore(WidgetTester tester, String name) async {
  await tester.tap(find.byTooltip('更多「$name」'));
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

  testWidgets('每行右边是「更多」而不是删除按钮', (tester) async {
    await pumpDrawer(
      tester,
      api: FakePlaylistApi([playlist(id: 1, name: '空的')]),
    );

    expect(find.byTooltip('更多「空的」'), findsOneWidget);
    expect(find.byTooltip('删除「空的」'), findsNothing, reason: '删除挪进菜单了');
  });

  testWidgets('「更多」菜单里有导出 / 重命名 / 删除', (tester) async {
    await pumpDrawer(
      tester,
      api: FakePlaylistApi([playlist(id: 1, name: '学习', trackCount: 3)]),
    );

    await openMore(tester, '学习');

    expect(find.text('导出'), findsOneWidget);
    expect(find.text('重命名'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
  });

  testWidgets('长按一行打开的是同一个菜单', (tester) async {
    await pumpDrawer(
      tester,
      api: FakePlaylistApi([playlist(id: 1, name: '夜跑', trackCount: 3)]),
    );

    await tester.longPress(find.text('夜跑'));
    await tester.pumpAndSettle();

    expect(find.text('导出'), findsOneWidget);
    expect(find.text('重命名'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
  });

  testWidgets('菜单里删除空列表：直接删，不弹确认', (tester) async {
    final api = FakePlaylistApi([playlist(id: 1, name: '空的')]);
    await pumpDrawer(tester, api: api);

    await openMore(tester, '空的');
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(api.calls, ['delete:1']);
    expect(find.text('空的'), findsNothing);
  });

  testWidgets('菜单里删除非空列表：先确认，取消则不动', (tester) async {
    final api = FakePlaylistApi([playlist(id: 1, name: '学习', trackCount: 9)]);
    await pumpDrawer(tester, api: api);

    await openMore(tester, '学习');
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除「学习」？'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(api.calls, isEmpty);
    expect(find.text('学习'), findsOneWidget);

    await openMore(tester, '学习');
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(api.calls, ['delete:1']);
  });

  testWidgets('菜单里重命名', (tester) async {
    final api = FakePlaylistApi([playlist(id: 3, name: '旧名字')]);
    await pumpDrawer(tester, api: api);

    await openMore(tester, '旧名字');
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    expect(find.text('重命名'), findsOneWidget, reason: '弹的是改名对话框');

    await tester.enterText(find.byType(TextField), '新名字');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(api.calls, ['rename:3:新名字']);
    expect(find.text('新名字'), findsOneWidget);
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

  testWidgets('导入：挑到文件就解析入库，并按结果给提示', (tester) async {
    final api = FakePlaylistApi();
    final files = FakeFiles(
      picked: PickedPlaylistFile(
        name: '夜跑.m3u8',
        bytes: Uint8List.fromList(utf8.encode('#EXTM3U\n/m/a.mp3\n')),
      ),
    );
    await pumpDrawer(tester, api: api, files: files);

    await tester.tap(find.byTooltip('导入播放列表（xspf / m3u8）'));
    await tester.pumpAndSettle();

    expect(files.calls, ['pick']);
    expect(api.fileCalls, ['import:夜跑.m3u8:#EXTM3U\n/m/a.mp3\n']);
    expect(find.text('已导入 2 首'), findsOneWidget);
    expect(find.text('导入的列表'), findsOneWidget, reason: '导入完要刷新列表');
  });

  testWidgets('导入：一条都没对上时说清楚「先扫描」', (tester) async {
    final api = FakePlaylistApi()
      ..importResult = const PlaylistImport(
        playlistId: 201,
        added: 0,
        missing: 3,
        missingPaths: <String>['/m/a.mp3'],
        skipped: 1,
      );
    final files = FakeFiles(
      picked: PickedPlaylistFile(
        name: 'mix.m3u8',
        bytes: Uint8List.fromList(<int>[0x23]),
      ),
    );
    await pumpDrawer(tester, api: api, files: files);

    await tester.tap(find.byTooltip('导入播放列表（xspf / m3u8）'));
    await tester.pumpAndSettle();

    expect(find.textContaining('一条都没对上'), findsOneWidget);
    expect(find.textContaining('扫描'), findsOneWidget);
  });

  testWidgets('导入：用户取消选择就什么都不做', (tester) async {
    final api = FakePlaylistApi();
    final files = FakeFiles();
    await pumpDrawer(tester, api: api, files: files);

    await tester.tap(find.byTooltip('导入播放列表（xspf / m3u8）'));
    await tester.pumpAndSettle();

    expect(files.calls, ['pick']);
    expect(api.fileCalls, isEmpty);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('导入：文件选择器报错时给提示而不是崩', (tester) async {
    final api = FakePlaylistApi();
    final files = FakeFiles()..fail = true;
    await pumpDrawer(tester, api: api, files: files);

    await tester.tap(find.byTooltip('导入播放列表（xspf / m3u8）'));
    await tester.pumpAndSettle();

    expect(find.textContaining('打不开文件'), findsOneWidget);
  });

  testWidgets('导出：先选格式，再把文本交给保存对话框', (tester) async {
    final api = FakePlaylistApi([playlist(id: 5, name: '学习')]);
    final files = FakeFiles();
    await pumpDrawer(tester, api: api, files: files);

    await openMore(tester, '学习');
    await tester.tap(find.text('导出'));
    await tester.pumpAndSettle();

    // 两种格式都列出来，各自带一句说明。
    expect(find.text('M3U8'), findsOneWidget);
    expect(find.text('XSPF'), findsOneWidget);

    await tester.tap(find.text('M3U8'));
    await tester.pumpAndSettle();

    expect(api.fileCalls, ['export:5:m3u8']);
    expect(files.calls, ['save:学习.m3u8:8']);
    expect(find.text('已导出「学习.m3u8」'), findsOneWidget);
  });

  testWidgets('导出：列表名里的非法字符被换掉', (tester) async {
    final api = FakePlaylistApi([playlist(id: 5, name: 'a/b:c*')]);
    final files = FakeFiles();
    await pumpDrawer(tester, api: api, files: files);

    await openMore(tester, 'a/b:c*');
    await tester.tap(find.text('导出'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('XSPF'));
    await tester.pumpAndSettle();

    expect(files.calls, ['save:a_b_c_.xspf:8']);
  });

  testWidgets('导出：用户在保存对话框点取消，就不出声', (tester) async {
    final api = FakePlaylistApi([playlist(id: 5, name: '学习')]);
    final files = _CancellingFiles();
    await pumpDrawer(tester, api: api, files: files);

    await openMore(tester, '学习');
    await tester.tap(find.text('导出'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('M3U8'));
    await tester.pumpAndSettle();

    expect(files.calls, ['save:学习.m3u8:8']);
    expect(find.byType(SnackBar), findsNothing);
  });

  group('importMessage', () {
    PlaylistImport result({int added = 0, int missing = 0, int skipped = 0}) =>
        PlaylistImport(
          playlistId: 1,
          added: added,
          missing: missing,
          missingPaths: const <String>[],
          skipped: skipped,
        );

    test('全对上：只说导入了多少', () {
      expect(importMessage(result(added: 5)), '已导入 5 首');
    });

    test('部分对不上：把条数带上', () {
      expect(importMessage(result(added: 5, missing: 2)), '已导入 5 首，2 条对不上');
    });

    test('一条都没对上：说清楚要先去扫描', () {
      final message = importMessage(result(missing: 7, skipped: 1));
      expect(message, contains('一条都没对上'));
      expect(message, contains('7 条'));
      expect(message, contains('1 条网络地址跳过'));
      expect(message, contains('扫描'));
    });
  });
}

/// 保存时永远返回「用户取消」（`null`）的桩。
class _CancellingFiles extends PlaylistFiles {
  final List<String> calls = [];

  @override
  Future<PickedPlaylistFile?> pick() async => null;

  @override
  Future<String?> save({required String name, required String text}) async {
    calls.add('save:$name:${text.length}');
    return null;
  }
}
