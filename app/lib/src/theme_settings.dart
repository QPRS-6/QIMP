import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// 强调色（出厂那支青）。
///
/// 换背景**不动它**：按钮、进度条、开关这些「有态度的颜色」跟底色是两件事，
/// 一起换掉用户会觉得「我明明只改了背景」。要能一起调，那是下一步的事。
const Color kAccentSeed = Colors.teal;

/// 出厂主题：没改过背景色时用它，跟以前一模一样。
ThemeData defaultAppTheme() =>
    ThemeData(colorSchemeSeed: kAccentSeed, useMaterial3: true);

/// 这个底色算亮底还是暗底。
///
/// 判据用的是 **HSL 的明度**（一半分界），不是 `computeLuminance()`：
/// 后者是感知加权过的相对亮度，中灰（#808080）只有 0.22，
/// 会掉进「暗底」那一侧——而中灰上其实黑字更清楚。
bool isDarkBackground(Color background) =>
    HSLColor.fromColor(background).lightness < 0.5;

/// 在这个底色上该用深字还是浅字（色块上的对勾、纯色底上的文字都用它）。
Color contrastInk(Color background) => isDarkBackground(background)
    ? const Color(0xFFF2F2F2)
    : const Color(0xFF1A1A1A);

/// 由背景色推一整套配色。
///
/// 为什么不能只改 `scaffoldBackgroundColor`：M3 里顶栏、卡片、弹窗、抽屉、底部条
/// 用的都是 `surface*` 那一族颜色，它们仍来自种子的**中性色**。只把页面底刷成深蓝，
/// 上面就会浮出一块块米白，而正文（`onSurface`）还是黑的——等于半个界面瞎了。
/// 所以整族一起推：底色就是用户选的那个色，文字反过来按明暗给，
/// 层叠色在底色上挪几个色阶。
ColorScheme backgroundScheme(Color background) {
  final dark = isDarkBackground(background);

  /// 在底色上挪一点明度（色相、饱和度都不动，免得偏色）。
  Color level(double delta) {
    final hsl = HSLColor.fromColor(background);
    return hsl.withLightness((hsl.lightness + delta).clamp(0.0, 1.0)).toColor();
  }

  return ColorScheme.fromSeed(
    seedColor: kAccentSeed,
    // 底色是暗的，就把整套配色按暗色主题生成：阴影、水波纹那些
    // 硬编码在组件里的深浅也跟着对。
    brightness: dark ? Brightness.dark : Brightness.light,
    // 页面底：用户选的那个色，一点不走样（Scaffold 默认就用它）。
    surface: background,
    // 层叠色（卡片 / 弹窗 / 菜单 / 抽屉 / 底部条）：对齐 M3 的色阶，
    // 亮底往下压、暗底往上提，于是「一层层浮起来」的层次还在。
    surfaceContainerLowest: level(dark ? -0.02 : 0.02),
    surfaceContainerLow: level(dark ? 0.04 : -0.02),
    surfaceContainer: level(dark ? 0.06 : -0.04),
    surfaceContainerHigh: level(dark ? 0.11 : -0.06),
    surfaceContainerHighest: level(dark ? 0.16 : -0.08),
    surfaceDim: level(dark ? 0.0 : -0.10),
    surfaceBright: level(dark ? 0.18 : 0.02),
    // 文字：亮底给深字、暗底给浅字（M3 的中性色 N-10 / N-90 那一档）。
    onSurface: dark ? const Color(0xFFE8E8E8) : const Color(0xFF1A1A1A),
    // 次要文字（歌手名、时长）：比正文浅一档，但还在同一个底上看得清。
    onSurfaceVariant: dark ? const Color(0xFFBFBFBF) : const Color(0xFF4A4A4A),
    // 描边 / 分隔线：夹在底色与文字之间的中间调。
    outline: level(dark ? 0.45 : -0.45),
    outlineVariant: level(dark ? 0.22 : -0.16),
    // 提示条（SnackBar）走的是「反色」：底深就用浅条子，反过来也一样，
    // 免得深色底上弹出一条更深的东西，看着像缺了一块。
    inverseSurface: dark ? const Color(0xFFE8E8E8) : const Color(0xFF2B2B2B),
    onInverseSurface: dark ? const Color(0xFF1A1A1A) : const Color(0xFFF2F2F2),
  );
}

/// 应用主题。`background` 为 `null` 就是出厂主题。
ThemeData appTheme(Color? background) => background == null
    ? defaultAppTheme()
    : ThemeData(useMaterial3: true, colorScheme: backgroundScheme(background));

/// `#RRGGBB`（大写）。存进 JSON 用，也显示在编辑页上。
String hexOf(Color color) =>
    '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// 反着来：认 `#RRGGBB` 或 `RRGGBB`；认不出来返回 `null`（当没设过）。
Color? parseHexColor(Object? text) {
  if (text is! String) return null;
  final hex = text.startsWith('#') ? text.substring(1) : text;
  if (hex.length != 6) return null;
  final rgb = int.tryParse(hex, radix: 16);
  return rgb == null ? null : Color(0xFF000000 | rgb);
}

/// 主题设置的落盘入口。
///
/// 写成应用私有目录下的一小份 JSON（跟 `library.db` 放一起）：这里只存一个颜色，
/// 为它引一个 `shared_preferences` 不划算。用 JSON 而不是一行纯文本，
/// 是为了以后加「强调色」「字号」时不必再换格式。
///
/// 读 / 写都**不往外抛**：读不出来（首次启动、宿主机测试没有 path_provider）
/// 就当没设过、用出厂主题；写不进去也只是「这次改的没记住」——
/// 两种都不值得弹个用户看不懂的错。
class ThemeStore {
  const ThemeStore();

  static const String _fileName = 'theme.json';
  static const String _key = 'background';

  Future<File> _file() async =>
      File('${(await getApplicationSupportDirectory()).path}/$_fileName');

  /// 读回上次选的背景色；没存过时返回 `null`。
  Future<Color?> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      return parseHexColor(decoded[_key]);
    } catch (_) {
      return null;
    }
  }

  /// 记下背景色（`null` = 回出厂主题）。
  Future<void> save(Color? color) async {
    try {
      final file = await _file();
      await file.writeAsString(
        jsonEncode(<String, String?>{_key: color == null ? null : hexOf(color)}),
      );
    } catch (_) {
      // 写不进去就算了：这次改的照样生效，只是下次打开回到上一份。
    }
  }
}

/// 主题设置：目前只有一项——**背景颜色**。
///
/// 用 `ChangeNotifier` 而不是 `ValueNotifier<Color?>`：以后要加「强调色」「深浅」时，
/// 通知这一头不用换（`MaterialApp` 那层只认「变了就重建」）。
///
/// 改一下**立刻生效、立刻落盘**，没有「保存」按钮——这是照桌面小部件那个设置页
/// 的做法来的（那边也是改完立刻重画），省得用户改完盯着屏幕猜「保存了没有」。
class ThemeSettings extends ChangeNotifier {
  ThemeSettings({this.store = const ThemeStore(), Color? background})
    : _background = background,
      _saved = background;

  /// 落盘的入口；测试里换成内存桩，免得宿主机上真的去写文件。
  final ThemeStore store;

  Color? _background;

  /// 已经写进文件的那一份。判断「这次要不要落盘」靠它，不能靠 `_background`：
  /// 拖滑块的过程中只改界面不写盘（松手才写，见 [setBackground]），
  /// 松手那一下的值与拖动中最后那一下是同一个，光看 `_background` 变化会漏掉这次写。
  Color? _saved;

  /// 背景色；`null` = 出厂主题（一切照旧）。
  Color? get background => _background;

  /// 当前该用的主题。
  ThemeData get theme => appTheme(_background);

  /// 从磁盘读回上次的选择（启动时调，第一帧之前）。
  Future<void> load() async {
    final saved = await store.load();
    if (saved == null) return;
    _background = saved;
    _saved = saved;
    notifyListeners();
  }

  /// 换背景色；`null` 表示回出厂主题。
  ///
  /// [save] 传 `false` 用于滑块拖动中：那一路会连着来几十次，每次都写文件没必要
  /// ——界面照样立刻跟着变，松手（`onChangeEnd`）再落盘一次。
  void setBackground(Color? color, {bool save = true}) {
    if (color != _background) {
      _background = color;
      notifyListeners();
    }
    if (save && color != _saved) {
      _saved = color;
      // 不等它写完：写文件那几毫秒不该挡着界面换色；真写失败了也只是
      // 「下次打开是旧色」，不值得把错误推到界面上。
      unawaited(store.save(color));
    }
  }
}
