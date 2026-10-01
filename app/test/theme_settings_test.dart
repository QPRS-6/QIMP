import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/src/theme_settings.dart';

/// 内存版落盘入口：宿主机上没有 path_provider，而且这样能看到「到底写了什么、写了几次」。
class FakeThemeStore extends ThemeStore {
  FakeThemeStore({this.saved});

  /// 假装文件里已经存着什么（`null` = 没存过）。
  Color? saved;

  /// 每次 `save` 的入参（含 `null`）。
  final List<Color?> writes = <Color?>[];

  @override
  Future<Color?> load() async => saved;

  @override
  Future<void> save(Color? color) async {
    writes.add(color);
    saved = color;
  }
}

/// 相对亮度（0 = 黑，1 = 白）。
double lum(Color color) => color.computeLuminance();

/// WCAG 的对比度：1（同色）到 21（纯黑对纯白）。
double contrastRatio(Color a, Color b) {
  final la = lum(a);
  final lb = lum(b);
  return la > lb ? (la + 0.05) / (lb + 0.05) : (lb + 0.05) / (la + 0.05);
}

void main() {
  group('由背景色推配色', () {
    test('不给背景色就是出厂主题，一点没变', () {
      final factory = defaultAppTheme();
      final theme = appTheme(null);
      expect(theme.colorScheme.primary, factory.colorScheme.primary);
      expect(theme.colorScheme.surface, factory.colorScheme.surface);
      expect(theme.scaffoldBackgroundColor, factory.colorScheme.surface);
      expect(theme.useMaterial3, isTrue);
    });

    test('亮底：底色就是选的那个色，文字转成深色', () {
      const white = Color(0xFFFFFFFF);
      final theme = appTheme(white);
      expect(theme.scaffoldBackgroundColor, white);
      expect(theme.colorScheme.surface, white);
      expect(theme.colorScheme.brightness, Brightness.light);
      expect(lum(theme.colorScheme.onSurface), lessThan(0.1));
      expect(contrastRatio(theme.colorScheme.onSurface, white),
          greaterThan(4.5));
    });

    test('暗底：文字转成浅色（不然就是深底黑字，等于看不见）', () {
      const navy = Color(0xFF0E1B2A);
      final theme = appTheme(navy);
      expect(theme.colorScheme.surface, navy);
      expect(theme.colorScheme.brightness, Brightness.dark);
      expect(lum(theme.colorScheme.onSurface), greaterThan(0.7));
      expect(contrastRatio(theme.colorScheme.onSurface, navy),
          greaterThan(4.5));
      // 次要文字（歌手名、时长）也得看得清。
      expect(contrastRatio(theme.colorScheme.onSurfaceVariant, navy),
          greaterThan(4.5));
    });

    test('中灰算亮底：黑字比白字清楚', () {
      const grey = Color(0xFF808080);
      expect(isDarkBackground(grey), isFalse);
      expect(contrastInk(grey), const Color(0xFF1A1A1A));
      expect(
        contrastRatio(contrastInk(grey), grey),
        greaterThan(contrastRatio(const Color(0xFFF2F2F2), grey)),
      );
    });

    test('层叠色从底色推：亮底往下压、暗底往上提，弹窗才浮得起来', () {
      const white = Color(0xFFFFFFFF);
      final light = appTheme(white).colorScheme;
      expect(lum(light.surfaceContainerLow), lessThan(lum(light.surface)));
      expect(
        lum(light.surfaceContainerHighest),
        lessThan(lum(light.surfaceContainerLow)),
      );

      const navy = Color(0xFF0E1B2A);
      final dark = appTheme(navy).colorScheme;
      expect(lum(dark.surfaceContainerLow), greaterThan(lum(dark.surface)));
      expect(
        lum(dark.surfaceContainerHighest),
        greaterThan(lum(dark.surfaceContainerLow)),
      );
    });

    test('换背景不动强调色：按钮、进度条还是那支青', () {
      expect(
        appTheme(const Color(0xFFFFFFFF)).colorScheme.primary,
        defaultAppTheme().colorScheme.primary,
      );
    });

    test('提示条走反色：深底上那条提示是浅的，字是深的', () {
      final scheme = appTheme(const Color(0xFF000000)).colorScheme;
      expect(lum(scheme.inverseSurface), greaterThan(lum(scheme.surface)));
      expect(lum(scheme.onInverseSurface), lessThan(lum(scheme.inverseSurface)));
    });
  });

  group('颜色的存 / 取', () {
    test('hex 来回一趟不变', () {
      expect(hexOf(const Color(0xFF0E1B2A)), '#0E1B2A');
      expect(parseHexColor('#0e1b2a'), const Color(0xFF0E1B2A));
      expect(parseHexColor('0E1B2A'), const Color(0xFF0E1B2A));
    });

    test('认不出来的当没设过', () {
      expect(parseHexColor(null), isNull);
      expect(parseHexColor(''), isNull);
      expect(parseHexColor('#12345'), isNull);
      expect(parseHexColor('#GGGGGG'), isNull);
      expect(parseHexColor(42), isNull);
    });
  });

  group('主题设置', () {
    test('改一下就落盘，下次启动还在', () async {
      final store = FakeThemeStore();
      final settings = ThemeSettings(store: store);
      var notified = 0;
      settings.addListener(() => notified++);

      settings.setBackground(const Color(0xFF0E1B2A));
      expect(settings.background, const Color(0xFF0E1B2A));
      expect(settings.theme.scaffoldBackgroundColor, const Color(0xFF0E1B2A));
      expect(notified, 1);
      expect(store.writes, [const Color(0xFF0E1B2A)]);

      // 换一份设置读回来 = 下次启动。
      final again = ThemeSettings(store: store);
      await again.load();
      expect(again.background, const Color(0xFF0E1B2A));
    });

    test('拖滑块时只改界面，松手才写一次', () {
      final store = FakeThemeStore(saved: const Color(0xFF000000));
      final settings = ThemeSettings(
        store: store,
        background: const Color(0xFF000000),
      );

      settings.setBackground(const Color(0xFF010101), save: false);
      settings.setBackground(const Color(0xFF020202), save: false);
      settings.setBackground(const Color(0xFF030303), save: false);
      expect(settings.background, const Color(0xFF030303), reason: '界面已经在变');
      expect(store.writes, isEmpty, reason: '拖动中不写文件');

      // 松手：值跟拖动中最后那一下是同一个——这就是 `_saved` 存在的理由。
      settings.setBackground(const Color(0xFF030303));
      expect(store.writes, [const Color(0xFF030303)]);
    });

    test('点回同一个色不重复写文件', () {
      final store = FakeThemeStore();
      final settings = ThemeSettings(store: store);
      settings.setBackground(const Color(0xFF000000));
      settings.setBackground(const Color(0xFF000000));
      expect(store.writes.length, 1);
    });

    test('回到出厂主题也是「改一下」：把 null 写进文件', () {
      final store = FakeThemeStore(saved: const Color(0xFF000000));
      final settings = ThemeSettings(
        store: store,
        background: const Color(0xFF000000),
      );
      settings.setBackground(null);
      expect(settings.background, isNull);
      expect(store.writes, [null]);
    });

    test('文件里没有（或读不出来）就用出厂主题，不报错', () async {
      final settings = ThemeSettings(store: FakeThemeStore());
      await settings.load();
      expect(settings.background, isNull);
      expect(
        settings.theme.scaffoldBackgroundColor,
        defaultAppTheme().colorScheme.surface,
      );
    });
  });
}
