import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:musicplayer/src/rust/api/library.dart' as ffi;

/// 导出播放列表时能选的格式。
///
/// 为什么不直接用生成代码里那个 `PlaylistFileFormat`：它的变体在 Dart 侧叫 `m3U`
/// （FRB 的数字分词规则），界面上到处写这个名字很别扭；而且**导入**根本用不着它——
/// 格式由文件内容决定（见 core 的 `detect_format`）。所以界面只认这一个枚举，
/// 与 FFI 之间的映射只写在这里一处。
enum PlaylistExportFormat {
  m3u8(
    extension: 'm3u8',
    label: 'M3U8',
    description: '一行一首路径，几乎所有播放器都认',
  ),
  xspf(
    extension: 'xspf',
    label: 'XSPF',
    description: '带标题与专辑的 XML，VLC / foobar2000 都认',
  );

  const PlaylistExportFormat({
    required this.extension,
    required this.label,
    required this.description,
  });

  /// 文件扩展名（不含点）。
  final String extension;

  /// 菜单 / 对话框上显示的名字。
  final String label;

  /// 一句话说明，帮用户选。
  final String description;

  /// 交给 Rust 的那份枚举。
  ffi.PlaylistFileFormat get toFfi => switch (this) {
    PlaylistExportFormat.m3u8 => ffi.PlaylistFileFormat.m3U,
    PlaylistExportFormat.xspf => ffi.PlaylistFileFormat.xspf,
  };
}

/// 用户挑中的那个列表文件。
class PickedPlaylistFile {
  const PickedPlaylistFile({required this.name, required this.bytes});

  /// 显示名（`夜跑.m3u8`）；Rust 侧从它取默认列表名，也从扩展名猜格式。
  final String name;

  /// 文件内容。列表文件都是纯文本，几十 KB 的样子。
  final Uint8List bytes;
}

/// 播放列表文件的读写桥，对应 `MainActivity` 里的 `com.qprs.musicplayer/files` 通道。
///
/// 为什么绕这一道：Android 上选文件 / 存文件必须走系统对话框（SAF），
/// 拿到的是 `content://` 而不是真实路径——core 的 `std::fs` 用不了它。
/// 所以由 Kotlin 侧读写字节，Dart 只负责搬进搬出。
///
/// 两个方法都**可能抛异常**（平台侧出错、宿主机测试里没有这个通道），
/// 调用方要自己接住并给个提示；「用户取消」不是异常，返回 `null`。
class PlaylistFiles {
  const PlaylistFiles();

  static const MethodChannel _channel = MethodChannel(
    'com.qprs.musicplayer/files',
  );

  /// 让用户挑一个 xspf / m3u8 文件。取消返回 `null`。
  Future<PickedPlaylistFile?> pick() async {
    final result = await _channel.invokeMapMethod<String, Object?>('pick');
    if (result == null) return null;
    final bytes = result['bytes'];
    if (bytes is! Uint8List) {
      // 平台侧只会给 Uint8List；真给了别的，当成「没挑中」，
      // 总比把一个来路不明的对象丢给 Rust 强。
      return null;
    }
    return PickedPlaylistFile(
      name: result['name'] as String? ?? 'playlist',
      bytes: bytes,
    );
  }

  /// 让用户挑个位置把 [text] 存成文件，返回落定后的文件名；取消返回 `null`。
  ///
  /// 传的是 UTF-8 字节而不是字符串：m3u8 / xspf 都是按 UTF-8 写的，
  /// 让平台侧原样写下去，避免中途再被谁按本地编码转一道。
  Future<String?> save({required String name, required String text}) =>
      _channel.invokeMethod<String>('save', <String, Object?>{
        'name': name,
        'bytes': Uint8List.fromList(utf8.encode(text)),
      });
}

/// 导出时的建议文件名：`夜跑` + `.m3u8`。
///
/// 列表名是用户随手起的，里面可能有 `/`、`*` 这类文件名非法字符（SAF 会直接拒绝），
/// 统一换成 `_`；整串都换没了就退回 `playlist`。
String suggestedFileName(String playlistName, PlaylistExportFormat format) {
  final cleaned = playlistName
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
      .trim();
  final base = cleaned.isEmpty ? 'playlist' : cleaned;
  return '$base.${format.extension}';
}
