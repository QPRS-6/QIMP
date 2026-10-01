import 'package:flutter/material.dart';
import 'package:musicplayer/src/playlist_api.dart';
import 'package:musicplayer/src/playlist_dialogs.dart';
import 'package:musicplayer/src/playlist_files.dart';
import 'package:musicplayer/src/rust/api/library.dart';

/// 抽屉里能切的三块主视图。
///
/// 「主页」是曲库页（统计 + 搜索 + 全部歌曲），「我的音乐」是按专辑 / 艺术家浏览，
/// 「队列」是当前播放队列。三者共用一个底部播放条，所以是切视图而不是压路由。
enum HomeView { library, myMusic, queue }

/// 一行播放列表上「更多」里能做的事。
enum _PlaylistAction { export, rename, delete }

/// 左侧抽屉：导航 + 播放列表管理。
///
/// 播放列表的增删改、以及导入 / 导出都在这里。点某个列表会打开它的曲目页；
/// 每行右边的 ⋮（以及**长按这一行**）会从按下去的位置弹出同一个「更多」菜单：
/// 导出 / 重命名 / 删除。长按和按钮合到一处，是因为以前长按是改名、按钮是删除——
/// 同一个东西上两种手势干两件不同的事，用户根本猜不到。
///
/// 列表是**同步**读出来的（本地 SQLite），所以直接放在 `initState` 里加载；
/// 原生能力缺失时（宿主机测试）退化成一行提示，不崩。
class AppDrawer extends StatefulWidget {
  const AppDrawer({
    super.key,
    required this.view,
    required this.onSelectView,
    this.playlistId,
    required this.onSelectPlaylist,
    this.api = const PlaylistApi(),
    this.files = const PlaylistFiles(),
  });

  /// 当前选中的视图（高亮用）。
  final HomeView view;

  final ValueChanged<HomeView> onSelectView;

  /// 当前打开的播放列表 id（`null` 表示不在任何列表里）。
  final int? playlistId;

  final ValueChanged<Playlist> onSelectPlaylist;

  /// 播放列表的读写入口；测试里换成内存桩。
  final PlaylistApi api;

  /// 选文件 / 存文件的平台通道；测试里换成桩（宿主机上没有它）。
  final PlaylistFiles files;

  @override
  State<AppDrawer> createState() => _AppDrawerState();
}

class _AppDrawerState extends State<AppDrawer> {
  List<Playlist> _playlists = const <Playlist>[];

  /// 读不出来时的原因（例如宿主机上根本没有原生库）。
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    try {
      final list = widget.api.list();
      setState(() {
        _playlists = list;
        _error = null;
      });
    } catch (e) {
      setState(() {
        _playlists = const <Playlist>[];
        _error = '$e';
      });
    }
  }

  void _close() => Navigator.of(context).maybePop();

  void _select(HomeView view) {
    _close();
    widget.onSelectView(view);
  }

  void _openPlaylist(Playlist playlist) {
    _close();
    widget.onSelectPlaylist(playlist);
  }

  Future<void> _createPlaylist() async {
    final name = await askPlaylistName(
      context,
      title: '新建播放列表',
      confirm: '创建',
    );
    if (name == null || !mounted) return;
    try {
      widget.api.create(name);
      _reload();
    } catch (e) {
      _toast('新建失败：$e');
    }
  }

  Future<void> _rename(Playlist playlist) async {
    final name = await askPlaylistName(
      context,
      title: '重命名',
      confirm: '保存',
      initial: playlist.name,
    );
    if (name == null || !mounted) return;
    try {
      widget.api.rename(playlist.id, name);
      _reload();
    } catch (e) {
      _toast('改名失败：$e');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 删除列表。**非空要二次确认**：列表里的歌是一首首攒出来的，
  /// 误触一下全没了太伤；空的就直接删。
  Future<void> _delete(Playlist playlist) async {
    final ok = await confirmDeletePlaylist(context, playlist);
    if (!ok || !mounted) return;
    try {
      widget.api.delete(playlist.id);
      _reload();
    } catch (e) {
      _toast('删除失败：$e');
    }
  }

  /// 导入一份列表文件：挑文件 → 解析入库 → 按结果给一句人话。
  Future<void> _import() async {
    final PickedPlaylistFile? picked;
    try {
      picked = await widget.files.pick();
    } catch (e) {
      _toast('打不开文件：$e');
      return;
    }
    if (picked == null || !mounted) return;

    try {
      final result = await widget.api.importFile(
        fileName: picked.name,
        bytes: picked.bytes,
      );
      if (!mounted) return;
      _reload();
      _toast(importMessage(result));
    } catch (e) {
      _toast('导入失败：$e');
    }
  }

  /// 导出：先问格式，再让用户挑保存位置（系统保存对话框），最后给提示。
  ///
  /// 文本由 Rust 生成（格式逻辑在 core 的 `playlist_file`，宿主机上就能测），
  /// 落盘交给平台侧——`content://` 那套只有 Kotlin 写得进去。
  Future<void> _export(Playlist playlist) async {
    final format = await chooseExportFormat(
      context,
      playlistName: playlist.name,
    );
    if (format == null || !mounted) return;

    final String text;
    try {
      text = widget.api.exportText(playlistId: playlist.id, format: format);
    } catch (e) {
      _toast('导出失败：$e');
      return;
    }

    try {
      final saved = await widget.files.save(
        name: suggestedFileName(playlist.name, format),
        text: text,
      );
      // 用户点了取消：什么都不提示，别拿「已取消」再烦他一次。
      if (saved != null && mounted) _toast('已导出「$saved」');
    } catch (e) {
      _toast('保存失败：$e');
    }
  }

  /// 某个控件在屏幕上的中心点——弹出菜单就落在按下去的那个位置。
  Offset _centerOf(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return Offset.zero;
    return box.localToGlobal(box.size.center(Offset.zero));
  }

  /// 弹出「更多」菜单。`position` 是**按下去的那个点**：
  /// 长按给的是手指位置，⋮ 给的是按钮中心。
  Future<void> _showMore(Playlist playlist, Offset position) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;

    final action = await showMenu<_PlaylistAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        overlay.size.width - position.dx,
        overlay.size.height - position.dy,
      ),
      items: const [
        PopupMenuItem(
          value: _PlaylistAction.export,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.ios_share),
            title: Text('导出'),
          ),
        ),
        PopupMenuItem(
          value: _PlaylistAction.rename,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.drive_file_rename_outline),
            title: Text('重命名'),
          ),
        ),
        PopupMenuItem(
          value: _PlaylistAction.delete,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.delete_outline),
            title: Text('删除'),
          ),
        ),
      ],
    );
    if (action == null || !mounted) return;

    switch (action) {
      case _PlaylistAction.export:
        await _export(playlist);
      case _PlaylistAction.rename:
        await _rename(playlist);
      case _PlaylistAction.delete:
        await _delete(playlist);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            _NavTile(
              icon: Icons.home_outlined,
              label: '主页',
              selected: widget.view == HomeView.library,
              onTap: () => _select(HomeView.library),
            ),
            _NavTile(
              icon: Icons.library_music_outlined,
              label: '我的音乐',
              selected: widget.view == HomeView.myMusic,
              onTap: () => _select(HomeView.myMusic),
            ),
            _NavTile(
              icon: Icons.queue_music,
              label: '队列',
              selected: widget.view == HomeView.queue,
              onTap: () => _select(HomeView.queue),
            ),
            const Divider(height: 16),
            // 这一排：＋ 新建、↓ 导入。两个都靠右。
            // 「编辑」按钮没了：改名 / 删除都在每行的「更多」里（长按同一行也一样）。
            Row(
              children: [
                const Spacer(),
                IconButton(
                  tooltip: '新建播放列表',
                  onPressed: _createPlaylist,
                  icon: const Icon(Icons.add),
                ),
                IconButton(
                  tooltip: '导入播放列表（xspf / m3u8）',
                  onPressed: _import,
                  icon: const Icon(Icons.file_download_outlined),
                ),
              ],
            ),
            Expanded(child: _buildPlaylists(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaylists(BuildContext context) {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          '播放列表读不出来：\n$_error',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    if (_playlists.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Text(
          '还没有播放列表。点上面的 ＋ 新建一个，\n或者用旁边的导入按钮导入一份 m3u8 / xspf，\n也可以直接在歌曲上长按把歌加进来。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: _playlists.length,
      itemBuilder: (context, index) {
        final playlist = _playlists[index];
        return GestureDetector(
          // 长按这一行 = 按右边那个 ⋮：同一个菜单，只是位置跟着手指走。
          onLongPressStart: (details) =>
              _showMore(playlist, details.globalPosition),
          child: ListTile(
            dense: true,
            selected: playlist.id == widget.playlistId,
            leading: const Icon(Icons.queue_music),
            title: Text(
              playlist.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text('${playlist.trackCount} 首'),
            // 「更多」：导出 / 重命名 / 删除，从按钮位置弹出。
            // 以前这里是个 ✕（直接删除），误触一次整份列表就没了。
            trailing: Builder(
              builder: (buttonContext) => IconButton(
                tooltip: '更多「${playlist.name}」',
                onPressed: () => _showMore(playlist, _centerOf(buttonContext)),
                icon: const Icon(Icons.more_vert),
              ),
            ),
            onTap: () => _openPlaylist(playlist),
          ),
        );
      },
    );
  }
}

/// 导入结果的提示语。
///
/// 三种情况分开说：全进去了、进去一部分、一条都没对上。最后那种必须讲明原因——
/// 列表确实建出来了、但里面是空的，不说清楚用户只会以为功能坏了
/// （多半是这些歌还没被扫进索引，先在主页扫一次再导入就行）。
String importMessage(PlaylistImport result) {
  final skipped = result.skipped > 0 ? '，${result.skipped} 条网络地址跳过' : '';
  if (result.added == 0) {
    return '一条都没对上：${result.missing} 条在曲库里找不到$skipped。'
        '先在主页扫描一次，再回来导入。';
  }
  final missing = result.missing > 0 ? '，${result.missing} 条对不上' : '';
  return '已导入 ${result.added} 首$missing$skipped';
}

/// 抽屉里的一行导航；选中时用主题色铺底（照图片里那种整行高亮）。
class _NavTile extends StatelessWidget {
  const _NavTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Material(
        color: selected ? colors.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(28),
        child: ListTile(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          leading: Icon(
            icon,
            color: selected ? colors.onPrimaryContainer : null,
          ),
          title: Text(
            label,
            style: TextStyle(
              color: selected ? colors.onPrimaryContainer : null,
              fontWeight: selected ? FontWeight.w600 : null,
            ),
          ),
          onTap: onTap,
        ),
      ),
    );
  }
}
