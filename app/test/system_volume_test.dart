// 系统音量桥：方法名/参数有没有对上，以及平台不在场时会不会把异常丢给界面。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/src/system_volume.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.qprs.musicplayer/playback');
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

  test('step：把格数交给平台侧，并把调整后的音量带回来', () async {
    mockPlatform((call) async => 0.4);

    expect(await SystemVolume.step(1), 0.4);
    expect(calls.single.method, 'adjustMusicVolume');
    expect(calls.single.arguments, {'steps': 1});
  });

  test('current：读当前音量', () async {
    mockPlatform((call) async => 0.25);

    expect(await SystemVolume.current(), 0.25);
    expect(calls.single.method, 'getMusicVolume');
    expect(calls.single.arguments, isNull);
  });

  test('平台侧报错时返回 null，而不是把异常丢给界面', () async {
    mockPlatform((call) async => throw PlatformException(code: '不支持'));

    expect(await SystemVolume.step(-1), isNull);
    expect(await SystemVolume.current(), isNull);
  });
}
