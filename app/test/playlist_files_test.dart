// 播放列表文件桥：方法名 / 参数有没有对上，取消与出错分不分得清。
//
// 宿主机上没有 `MainActivity`，所以平台侧用 mock 顶替——和 `system_volume_test.dart`
// 是同一个套路：这里断言的是「界面 ↔ 平台」这条线的契约。
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/src/playlist_files.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.qprs.musicplayer/files');
  final calls = <MethodCall>[];

  void mockPlatform(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) {
          calls.add(call);
          return handler(call);
        });
  }

  tearDown(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('pick：把平台给的字节原样带回来', () async {
    final bytes = Uint8List.fromList(utf8.encode('#EXTM3U\n/m/a.mp3\n'));
    mockPlatform(
      (call) async => <String, Object?>{'name': '夜跑.m3u8', 'bytes': bytes},
    );

    final picked = await const PlaylistFiles().pick();

    expect(calls.single.method, 'pick');
    expect(picked?.name, '夜跑.m3u8');
    expect(picked?.bytes, bytes);
  });

  test('pick：用户取消（平台回 null）时返回 null', () async {
    mockPlatform((call) async => null);

    expect(await const PlaylistFiles().pick(), isNull);
  });

  test('pick：平台给不出字节时当成没挑中，而不是把怪东西丢给上层', () async {
    mockPlatform((call) async => <String, Object?>{'name': 'x.m3u8'});

    expect(await const PlaylistFiles().pick(), isNull);
  });

  test('save：名字与 UTF-8 字节一起交给平台，并带回保存后的文件名', () async {
    mockPlatform((call) async => '夜跑.m3u8');

    final saved = await const PlaylistFiles().save(
      name: '夜跑.m3u8',
      text: '#EXTM3U\n',
    );

    expect(saved, '夜跑.m3u8');
    expect(calls.single.method, 'save');
    final arguments = calls.single.arguments as Map<Object?, Object?>;
    expect(arguments['name'], '夜跑.m3u8');
    // 中文按 UTF-8 走：平台侧拿到的是字节，不是被谁按本地编码转过的字符串。
    expect(utf8.decode(arguments['bytes']! as Uint8List), '#EXTM3U\n');
  });

  test('save：用户在保存对话框里取消，返回 null', () async {
    mockPlatform((call) async => null);

    expect(
      await const PlaylistFiles().save(name: 'a.m3u8', text: 'x'),
      isNull,
    );
  });

  test('平台侧报错时把异常交给调用方（界面要自己接住并提示）', () async {
    mockPlatform(
      (call) async => throw PlatformException(code: 'pick_failed', message: '读不出'),
    );

    await expectLater(const PlaylistFiles().pick(), throwsA(isA<PlatformException>()));
    await expectLater(
      const PlaylistFiles().save(name: 'a.m3u8', text: 'x'),
      throwsA(isA<PlatformException>()),
    );
  });

  group('suggestedFileName', () {
    test('名字加上对应扩展名', () {
      expect(suggestedFileName('夜跑', PlaylistExportFormat.m3u8), '夜跑.m3u8');
      expect(suggestedFileName('夜跑', PlaylistExportFormat.xspf), '夜跑.xspf');
    });

    test('文件名里的非法字符换成下划线', () {
      expect(
        suggestedFileName('a/b:c*?"<>|', PlaylistExportFormat.xspf),
        'a_b_c______.xspf',
      );
    });

    test('名字是空的时候退回 playlist', () {
      expect(suggestedFileName('   ', PlaylistExportFormat.m3u8), 'playlist.m3u8');
    });
  });

  test('导出格式与 FFI 枚举的映射：一个 m3u8 一个 xspf', () {
    expect(
      PlaylistExportFormat.values.map((format) => format.extension).toList(),
      ['m3u8', 'xspf'],
    );
  });
}
