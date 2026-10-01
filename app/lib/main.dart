import 'package:flutter/material.dart';
import 'package:musicplayer/src/rust/api/app.dart';
import 'package:musicplayer/src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 加载 libmusicplayer_ffi.so，并触发 Rust 侧的 `#[frb(init)] init_app()`
  await RustLib.init();
  runApp(const MusicPlayerApp());
}

class MusicPlayerApp extends StatelessWidget {
  const MusicPlayerApp({super.key});

  /// 应用标题，集中一处，避免魔法字符串散落。
  static const String title = '本地音乐播放器';

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: title,
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const CoreSelfCheckPage(),
    );
  }
}

/// Rust 核心自检结果。
class CoreSelfCheck {
  const CoreSelfCheck({required this.version, required this.extensions});

  final String version;
  final List<String> extensions;
}

/// 读取核心信息。刻意做成顶层函数，方便测试直接调用。
Future<CoreSelfCheck> loadCoreSelfCheck() async => CoreSelfCheck(
  version: coreVersion(),
  extensions: defaultAudioExtensions(),
);

/// 自检页：证明“Flutter → Rust”这条链路真的通了。
///
/// 目前是占位界面，后续会被曲库 / 播放器页面替换。
class CoreSelfCheckPage extends StatelessWidget {
  const CoreSelfCheckPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(MusicPlayerApp.title)),
      body: FutureBuilder<CoreSelfCheck>(
        future: loadCoreSelfCheck(),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _Hint(
              icon: Icons.error_outline,
              text: 'Rust 核心未就绪：${snapshot.error}',
            );
          }
          final info = snapshot.requireData;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _Hint(
                icon: Icons.check_circle_outline,
                text: 'Rust 核心已连接：v${info.version}',
              ),
              const SizedBox(height: 20),
              Text(
                '支持格式（${info.extensions.length} 种）',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final ext in info.extensions) Chip(label: Text(ext)),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
      ],
    );
  }
}
