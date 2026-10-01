import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/main.dart';

/// 这一层测试只覆盖 Dart 侧行为，不加载 `libmusicplayer_ffi.so`：
/// `flutter test` 跑在宿主机 VM 上，没有 Android 的 `.so`，因此 FFI 调用必然失败，
/// 而“失败时给出可读提示、不崩溃”正是这里要断言的行为。
void main() {
  testWidgets('未初始化 Rust 核心时显示错误提示而非崩溃', (tester) async {
    await tester.pumpWidget(const MusicPlayerApp());
    await tester.pumpAndSettle();

    expect(find.textContaining('Rust 核心未就绪'), findsOneWidget);
  });

  test('应用标题保持稳定', () {
    expect(MusicPlayerApp.title, '本地音乐播放器');
  });
}
