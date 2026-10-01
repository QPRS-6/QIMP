import 'package:musicplayer/src/rust/api/library.dart';

/// 曲库的读写入口。
///
/// 与 `PlaylistApi` / `ProgressApi` 同一个套路：默认实现直接打 FFI（本地 SQLite，
/// 同步返回，快到不值得到处 await）；宿主机测试里没有 `.so`，所以留了这个可替换点，
/// 让界面代码不直接依赖“原生能力一定存在”。
///
/// 这里说的**曲库**是用户挑出来的那些歌（`in_library = 1`）：扫描只建索引，
/// 收不收进来由用户在主页上决定。所以列表 / 搜索 / 统计都只覆盖曲库，
/// 而「还没入库」是另外一份——主页的「＋ 添加歌曲」列的正是它。
class LibraryApi {
  const LibraryApi();

  /// 曲库里的歌，按标题排序。「我的音乐」的分组浏览也用它。
  List<Track> tracks({int limit = 2000}) => listLibraryTracks(
    sort: SortKey.title,
    descending: false,
    limit: limit,
  );

  /// 在**曲库**里搜索（列表上看到什么就搜什么）。
  List<Track> search(String query, {int limit = 500}) =>
      searchTracks(query: query, limit: limit);

  /// 已经建了索引、但还没收进曲库的歌。
  List<Track> pending({int limit = 2000}) => listPendingTracks(limit: limit);

  /// 曲库统计：主页底部那行「452 / 27:27:36 / 9.75 GB」。
  Stats stats() => libraryStats();

  /// 把歌曲收进曲库，返回真正加进去的条数。
  int add(List<int> trackIds) => addToLibrary(trackIds: trackIds);

  /// 把歌曲移出曲库，返回真正移出的条数。
  ///
  /// 只清标记：文件与索引记录都还在，所以还能在「＋ 添加歌曲」里找回来。
  int remove(List<int> trackIds) => removeFromLibrary(trackIds: trackIds);

  /// 把歌曲从储存里删掉（文件 + 索引记录）。**不可恢复**，调用前必须确认。
  Future<DeleteSummary> deleteFiles(List<int> trackIds) =>
      deleteFromStorage(trackIds: trackIds);
}
