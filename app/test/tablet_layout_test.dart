// 「是不是平板 / 横没横过来 / 主页该不该锁竖屏」这几个判断的用例：只看尺寸，
// 不看型号 / 方向。
import 'package:flutter/services.dart' show DeviceOrientation;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/src/tablet_layout.dart';

void main() {
  test('最短边不到 600 一律算手机', () {
    expect(useTabletLayout(const Size(360, 800)), isFalse, reason: '常见手机竖屏');
    expect(useTabletLayout(const Size(800, 360)), isFalse, reason: '手机横过来最短边没变');
    expect(useTabletLayout(const Size(599, 1024)), isFalse, reason: '差一像素也还是手机');
    expect(useTabletLayout(const Size(411, 891)), isFalse);
  });

  test('最短边到了 600 就是平板（跟 Android 的 sw600dp 一致）', () {
    expect(useTabletLayout(const Size(600, 960)), isTrue, reason: '刚够线的小平板');
    expect(useTabletLayout(const Size(960, 600)), isTrue, reason: '横过来还是同一台');
    expect(useTabletLayout(const Size(800, 1280)), isTrue, reason: '平板竖屏');
    expect(useTabletLayout(const Size(1280, 800)), isTrue, reason: '平板横屏');
    expect(useTabletLayout(const Size(1600, 2560)), isTrue);
  });

  test('折叠屏展开 / 桌面窗口：尺寸到了就按平板排', () {
    expect(useTabletLayout(const Size(673, 841)), isTrue, reason: '折叠屏展开态');
    expect(useTabletLayout(const Size(1024, 1366)), isTrue);
  });

  test('横竖屏：宽比高长就是横着拿的', () {
    expect(isLandscape(const Size(800, 360)), isTrue, reason: '手机横屏');
    expect(isLandscape(const Size(1280, 800)), isTrue, reason: '平板横屏');
    expect(isLandscape(const Size(360, 800)), isFalse, reason: '手机竖屏');
    expect(isLandscape(const Size(800, 1280)), isFalse, reason: '平板竖屏');
    expect(isLandscape(const Size(600, 600)), isFalse, reason: '方的当竖屏办');
  });

  test('主页方向：手机锁竖屏，平板不锁', () {
    const portraitOnly = [
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ];
    expect(homeOrientations(const Size(360, 800)), portraitOnly);
    expect(
      homeOrientations(const Size(800, 360)),
      portraitOnly,
      reason: '手机横着拿也一样：最短边没变，还是手机',
    );
    expect(
      homeOrientations(const Size(800, 1280)),
      DeviceOrientation.values,
      reason: '平板不锁：11 寸横着拿是常态',
    );
    expect(homeOrientations(const Size(1280, 800)), DeviceOrientation.values);
  });
}
