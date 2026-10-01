import 'package:flutter/material.dart';
import 'package:musicplayer/src/app_info.dart';
import 'package:musicplayer/src/library_page.dart';
import 'package:musicplayer/src/rust/frb_generated.dart';
import 'package:musicplayer/src/theme_settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 加载 libmusicplayer_ffi.so，并触发 Rust 侧的 `#[frb(init)] init_app()`
  await RustLib.init();
  // 主题要在跑第一帧之前读回来：晚一步就会先闪一下出厂配色，再跳成用户选的底色。
  final theme = ThemeSettings();
  await theme.load();
  runApp(MusicPlayerApp(themeSettings: theme));
}

class MusicPlayerApp extends StatelessWidget {
  const MusicPlayerApp({super.key, required this.themeSettings});

  /// 外观设置（目前就是背景色）。主页右上角那颗调色板改的就是它。
  final ThemeSettings themeSettings;

  @override
  Widget build(BuildContext context) {
    // 主题一变整棵树重建：`MaterialApp.theme` 是构造参数，
    // 除了重建没有别的地方能把它换掉。
    return AnimatedBuilder(
      animation: themeSettings,
      builder: (context, _) => MaterialApp(
        title: kAppTitle,
        theme: themeSettings.theme,
        home: LibraryPage(themeSettings: themeSettings),
      ),
    );
  }
}
