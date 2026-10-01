import 'dart:typed_data';

import 'package:musicplayer/src/playlist_files.dart';
import 'package:musicplayer/src/rust/api/library.dart';

/// 播放列表的读写入口。
///
/// 默认实现直接打 FFI（本地 SQLite，同步返回，快到不值得到处 await）；
/// 宿主机测试里没有 `.so`，所以留了一个可替换点——和 `LibraryPage.accessProbe`
/// 是同一个套路：让界面代码不直接依赖“原生能力一定存在”。
class PlaylistApi {
  const PlaylistApi();

  /// 所有列表（按名字排序）。
  List<Playlist> list() => playlists();

  /// 新建，返回新列表的 id。
  int create(String name) => createPlaylist(name: name);

  void rename(int playlistId, String name) =>
      renamePlaylist(playlistId: playlistId, name: name);

  /// 删除列表。列表里的条目一起没了，曲目本身不动。
  void delete(int playlistId) => deletePlaylist(playlistId: playlistId);

  /// 列表里的曲目（按用户排的顺序）。
  List<Track> tracks(int playlistId) => playlistTracks(playlistId: playlistId);

  /// 把一首歌加进列表；已经在里面时返回 `false`。
  bool add(int playlistId, int trackId) =>
      addToPlaylist(playlistId: playlistId, trackId: trackId);

  /// 把一首歌移出列表；不在里面时返回 `false`。
  bool remove(int playlistId, int trackId) =>
      removeFromPlaylist(playlistId: playlistId, trackId: trackId);

  /// 导入一份列表文件（xspf / m3u8），返回新建列表的 id 与统计。
  ///
  /// 只收**内容**：文件是用户用系统对话框挑的（`PlaylistFiles.pick`），
  /// 解析与落库都在 Rust 侧。
  Future<PlaylistImport> importFile({
    required String fileName,
    required Uint8List bytes,
  }) => importPlaylist(fileName: fileName, bytes: bytes);

  /// 把列表导出成文本，交给 `PlaylistFiles.save` 落盘。
  String exportText({
    required int playlistId,
    required PlaylistExportFormat format,
  }) => exportPlaylist(playlistId: playlistId, format: format.toFfi);
}
