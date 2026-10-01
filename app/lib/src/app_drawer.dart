import 'package:flutter/material.dart';
import 'package:musicplayer/src/playlist_api.dart';
import 'package:musicplayer/src/playlist_dialogs.dart';
import 'package:musicplayer/src/rust/api/library.dart';

/// 抽屉里能切的三块主视图。
///
/// 「主页」是曲库页（统计 + 搜索 + 全部歌曲），「我的音乐」是按专辑 / 艺术家浏览，
/// 「队列」是当前播放队列。三者共用一个底部播放条，所以是切视图而不是压路由。
enum HomeView { library, myMusic, queue }

/// 左侧抽屉：导航 + 播放列表管理。
///
/// 播放列表的增删改都在这里（新建 / 改名 / 删除），点某个列表会打开它的曲目页。
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
  });

  /// 当前选中的视图（高亮用）。
  final HomeView view;

  final ValueChanged<HomeView> onSelectView;

  /// 当前打开的播放列表 id（`null` 表示不在任何列表里）。
  final int? playlistId;

  final ValueChanged<Playlist> onSelectPlaylist;

  /// 播放列表的读写入口；测试里换成内存桩。
  final PlaylistApi api;

  @override
  State<AppDrawer> createState() => _AppDrawerState();
}

class _AppDrawerState extends State<AppDrawer> {
  List<Playlist> _playlists = const <Playlist>[];

  /// 读不出来时的原因（例如宿主机上根本没有原生库）。
  String? _error;

  /// 编辑模式：点一行变成「改名」，删除按钮照旧。
  bool _editing = false;

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
            // 图片里就是这一排：＋新建、✎进编辑模式。两个都靠右。
            Row(
              children: [
                const Spacer(),
                IconButton(
                  tooltip: '新建播放列表',
                  onPressed: _createPlaylist,
                  icon: const Icon(Icons.add),
                ),
                IconButton(
                  tooltip: _editing ? '退出编辑' : '编辑（改名 / 删除）',
                  onPressed: () => setState(() => _editing = !_editing),
                  icon: Icon(_editing ? Icons.check : Icons.edit),
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
          '还没有播放列表。点上面的 ＋ 新建一个，\n然后在歌曲上长按就能加进来。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: _playlists.length,
      itemBuilder: (context, index) {
        final playlist = _playlists[index];
        return ListTile(
          dense: true,
          selected: playlist.id == widget.playlistId,
          leading: Icon(_editing ? Icons.edit_note : Icons.queue_music),
          title: Text(
            playlist.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text('${playlist.trackCount} 首'),
          trailing: IconButton(
            tooltip: '删除「${playlist.name}」',
            onPressed: () => _delete(playlist),
            icon: const Icon(Icons.close),
          ),
          onTap: () => _editing ? _rename(playlist) : _openPlaylist(playlist),
        );
      },
    );
  }
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
