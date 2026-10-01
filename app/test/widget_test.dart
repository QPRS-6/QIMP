import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/src/app_info.dart';
import 'package:musicplayer/src/library_page.dart';

/// 这些用例跑在宿主机的 Dart VM 上：既没有 Android 的 `.so`，也没有 MethodChannel 的实现。
/// 因此这里把“权限查询”换成桩，断言的是**优雅降级**——失败时给出可读提示，而不是白屏或崩溃。
void main() {
  testWidgets('未授权时展示授权引导页', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: LibraryPage(accessProbe: () async => false)),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('所有文件访问'), findsOneWidget);
    expect(find.text('去授权'), findsOneWidget);
  });

  testWidgets('原生能力缺失时报错而不是崩溃', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryPage(
          accessProbe: () async => throw MissingPluginException('测试环境没有原生实现'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('初始化失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  test('应用标题保持稳定', () {
    expect(kAppTitle, '本地音乐播放器');
  });
}
