import 'package:flutter/material.dart';
import 'package:musicplayer/src/app_info.dart';
import 'package:musicplayer/src/library_page.dart';
import 'package:musicplayer/src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 加载 libmusicplayer_ffi.so，并触发 Rust 侧的 `#[frb(init)] init_app()`
  await RustLib.init();
  runApp(const MusicPlayerApp());
}

class MusicPlayerApp extends StatelessWidget {
  const MusicPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: kAppTitle,
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const LibraryPage(),
    );
  }
}
