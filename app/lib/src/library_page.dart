import 'dart:async';

// Flutter 的 material 也导出了一个 `RepeatMode`（重复动画用）。
// 这里要用的是播放器的循环模式，所以把 Flutter 那个藏起来，避免歧义。
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:musicplayer/src/add_to_playlist.dart';
import 'package:musicplayer/src/app_drawer.dart';
import 'package:musicplayer/src/app_info.dart';
import 'package:musicplayer/src/format.dart';
import 'package:musicplayer/src/my_music.dart';
import 'package:musicplayer/src/now_playing_bar.dart';
import 'package:musicplayer/src/playback_service.dart';
import 'package:musicplayer/src/playlist_api.dart';
import 'package:musicplayer/src/playlist_page.dart';
import 'package:musicplayer/src/player_page.dart';
import 'package:musicplayer/src/queue_store.dart';
import 'package:musicplayer/src/queue_view.dart';
import 'package:musicplayer/src/rust/api/library.dart';
import 'package:musicplayer/src/rust/api/player.dart';
import 'package:musicplayer/src/sleep_timer.dart';
import 'package:musicplayer/src/storage.dart';
import 'package:musicplayer/src/track_tile.dart';
import 'package:path_provider/path_provider.dart';

/// 曲库页：授权 → 打开数据库 → 扫描 → 列表 / 搜索。
///
/// 流程上区分两种“失败”：
/// - 没有存储权限：给一屏指引，点按钮跳系统设置；
/// - 其它异常：直接显示错误文本，避免用户面对一个白屏。

/// 权限查询的注入点：默认走真实 MethodChannel；测试里可替换成确定性的桩。
typedef AccessProbe = Future<bool> Function();

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    this.accessProbe = StorageAccess.granted,
    this.playlistApi = const PlaylistApi(),
  });

  /// 返回 `true` 表示已获得存储访问权。
  final AccessProbe accessProbe;

  /// 播放列表的读写入口（抽屉 / 列表页用）；测试里换成内存桩。
  final PlaylistApi playlistApi;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> with WidgetsBindingObserver {
  /// `null` 表示还没查出来（首屏转圈）。
  bool? _hasAccess;
  bool _busy = false;
  String? _error;
  Stats? _stats;
  List<Track> _tracks = const <Track>[];
  List<String> _roots = const <String>[];
  final TextEditingController _search = TextEditingController();

  /// 抽屉里选中的主视图（主页 / 我的音乐 / 队列）。
  HomeView _view = HomeView.library;

  /// 当前打开的播放列表（抽屉高亮用；`null` = 不在任何列表里）。
  int? _playlistId;

  /// **不带搜索过滤**的整份曲目。「我的音乐」的分组浏览用它：
  /// 搜索框里非空时 `_tracks` 只剩一半，分组会少一半的专辑。
  List<Track>? _allTracks;

  /// 当前播放队列（Dart 侧镜像）。队列视图读它，换队列的地方写它。
  final PlayQueueStore _queue = PlayQueueStore();

  /// 播放状态快照。只让底部播放条监听它，避免每 500ms 重建整个曲目列表。
  final ValueNotifier<PlayerSnapshot?> _player = ValueNotifier<PlayerSnapshot?>(
    null,
  );

  /// 正在播放的曲目（按 id 缓存），用于列表被搜索过滤时仍能在播放条上显示。
  int _playingTrackId = 0;
  Track? _playingTrack;

  Timer? _ticker;

  /// 跳转后的一次性补刷：`seek` 由播放线程异步执行，
  /// 立刻取到的快照还是旧位置（进度条那边会先把目标锁住）。
  Timer? _seekCatchUp;

  /// 定时播放（睡眠定时）。放在这一层而不是全屏播放界面里：
  /// 退出播放界面之后倒计时还得继续走。
  late final SleepTimer _sleepTimer;

  @override
  void initState() {
    super.initState();
    // 定时播放：到点暂停而不是停止——醒来后再点一下播放就能接着听。
    _sleepTimer = SleepTimer(onFire: () => _runPlayerAction(playerPause));
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _seekCatchUp?.cancel();
    _sleepTimer.dispose();
    _player.dispose();
    _queue.dispose();
    _search.dispose();
    super.dispose();
  }

  /// 从系统授权页返回时触发：权限可能刚被授予，必须复查一次。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _hasAccess == false) {
      _bootstrap();
    }
  }

  Future<void> _bootstrap() async {
    try {
      if (!await widget.accessProbe()) {
        setState(() => _hasAccess = false);
        return;
      }
      // 数据库放应用私有目录：不需要权限，也不会被别的应用改动。
      final dir = await getApplicationSupportDirectory();
      openLibrary(dbPath: '${dir.path}/library.db');
      // 打开音频设备（幂等）。放在权限之后：没权限时不该占用音频设备。
      openPlayer();
      _roots = suggestScanRoots();
      _reload();
      // 播放进度由轮询快照提供：500ms 一次，肉眼看进度条足够顺滑。
      _ticker ??= Timer.periodic(
        const Duration(milliseconds: 500),
        (_) => _refreshPlayer(),
      );
      _refreshPlayer();
      setState(() {
        _hasAccess = true;
        _error = null;
      });
    } catch (e) {
      setState(() {
        _hasAccess = true;
        _error = '初始化失败：$e';
      });
    }
  }

  /// 读取列表。本地 SQLite 查几千首是毫秒级，所以直接用同步接口，省掉一屏 loading。
  ///
  /// 搜索框为空时顺手把「整份曲目」也存下来（我的音乐 / 队列要按 id 回查标题）。
  void _reload() {
    final query = _search.text.trim();
    if (query.isEmpty) {
      final all = listTracks(
        sort: SortKey.title,
        descending: false,
        limit: 2000,
      );
      _allTracks = all;
      _tracks = all;
    } else {
      _tracks = searchTracks(query: query, limit: 500);
    }
    _stats = libraryStats();
    setState(() {});
  }

  /// 单独把整份曲目读一遍（切到「我的音乐」时用：可能启动时搜索框里就有词）。
  void _loadAllTracks() {
    try {
      final all = listTracks(
        sort: SortKey.title,
        descending: false,
        limit: 2000,
      );
      _allTracks = all;
      setState(() {});
    } catch (e) {
      _toast('读取曲库失败：$e');
    }
  }

  Future<void> _scan({required bool full}) async {
    setState(() => _busy = true);
    try {
      final summary = await scanLibrary(
        roots: _roots,
        mode: full ? ScanMode.full : ScanMode.incremental,
      );
      // 曲库变了，分组浏览那份缓存作废。
      _allTracks = null;
      _reload();
      _toast(
        '扫描完成：新增 ${summary.added}，更新 ${summary.updated}，'
        '移除 ${summary.removed}，跳过 ${summary.skipped}，'
        '耗时 ${summary.elapsedMs} ms',
      );
    } catch (e) {
      _toast('扫描失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 轮询播放状态。引擎还没初始化时静默忽略——首屏可能还没走到 `openPlayer`。
  void _refreshPlayer() {
    try {
      final snapshot = playerSnapshot();
      _rememberPlayingTrack(snapshot);
      _player.value = snapshot;
    } catch (_) {
      // 忽略：下一轮会再试，不值得往界面上抛错误。
    }
  }

  /// 记住正在播放的曲目。
  ///
  /// 搜索会把列表过滤成不含正在播放的那首；此时播放条就查不到标题与时长，
  /// 进度条会瞬间失去刻度（滑块贴到最左边）。这里留一份缓存兜底。
  void _rememberPlayingTrack(PlayerSnapshot snapshot) {
    if (snapshot.trackId <= 0) {
      _playingTrackId = 0;
      _playingTrack = null;
      return;
    }
    if (snapshot.trackId == _playingTrackId) return;
    _playingTrackId = snapshot.trackId;
    _playingTrack = _lookupTrack(snapshot.trackId);
  }

  /// 统一的播放操作包装：出错提示用户，结束后刷新一次快照。
  ///
  /// `ensureService` 用于「可能会让声音响起来」的操作（播放 / 暂停 / 切歌）：
  /// 顺手确认一下前台服务在跑，否则息屏后系统随时会回收进程。
  void _runPlayerAction(void Function() action, {bool ensureService = false}) {
    if (ensureService) {
      PlaybackService.start();
    }
    try {
      action();
    } catch (e) {
      _toast('$e');
    }
    _refreshPlayer();
  }

  /// 从当前列表的第 `index` 首开始播放（列表本身就是播放队列）。
  void _playAt(int index) => _playTracks(_tracks, index);

  /// 播放一组曲目（从第 `index` 首开始）。
  ///
  /// 曲库页、专辑/艺术家页、播放列表页都走这里：换队列的地方只该有一处，
  /// 队列镜像（抽屉里的「队列」视图）也只在这里更新。
  void _playTracks(List<Track> tracks, int index) {
    if (tracks.isEmpty) return;
    // 用户点了某一首：此时 App 一定在前台，正好可以拉起前台服务。
    PlaybackService.start();
    try {
      final entries = queueEntriesOf(tracks);
      setPlayQueue(entries: entries, startAt: index, autoplay: true);
      _queue.replace(entries);
    } catch (e) {
      _toast('无法播放：$e');
    }
    _refreshPlayer();
  }

  /// 跳到队列里的某一首（队列本身不变，只换当前项）。
  void _jumpTo(int index) {
    final entries = _queue.entries.value;
    if (index < 0 || index >= entries.length) return;
    PlaybackService.start();
    try {
      setPlayQueue(entries: entries, startAt: index, autoplay: true);
    } catch (e) {
      _toast('无法播放：$e');
    }
    _refreshPlayer();
  }

  /// 切主视图（抽屉里点的那三个）。
  void _selectView(HomeView view) {
    setState(() => _view = view);
    if (view == HomeView.myMusic && _allTracks == null) {
      _loadAllTracks();
    }
  }

  /// 打开一个播放列表：列表页有自己的返回箭头与编辑模式，所以走路由压栈。
  void _openPlaylist(Playlist playlist) {
    setState(() => _playlistId = playlist.id);
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => PlaylistPage(
              playlist: playlist,
              player: _player,
              queue: _queue,
              api: widget.playlistApi,
            ),
          ),
        )
        .whenComplete(() {
          if (mounted) setState(() => _playlistId = null);
        });
  }

  /// 长按曲目：加入某个播放列表。
  Future<void> _addToPlaylist(Track track) =>
      showAddToPlaylist(context, track: track, api: widget.playlistApi);

  /// 跳转进度。播放线程消化口令是异步的，所以隔一小会儿再补一次快照，
  /// 让进度条尽快回到真实位置（进度条自己还有「追不上就解锁」的兜底）。
  void _seekTo(int positionMs) {
    _runPlayerAction(() => playerSeek(positionMs: positionMs));
    _seekCatchUp?.cancel();
    _seekCatchUp = Timer(const Duration(milliseconds: 120), _refreshPlayer);
  }

  /// 循环模式：关闭 → 列表循环 → 单曲循环 → 关闭。
  void _cycleRepeat() {
    const order = [RepeatMode.off, RepeatMode.all, RepeatMode.one];
    final current = _player.value?.repeat ?? RepeatMode.off;
    final next = order[(order.indexOf(current) + 1) % order.length];
    _runPlayerAction(() => playerSetRepeat(mode: next));
  }

  /// 随机播放开关。
  ///
  /// 与循环模式是两个独立的维度：随机决定「下一首是谁」，循环决定「一轮放完怎么办」，
  /// 两者可以同时生效（例如「随机 + 列表循环」＝ 每轮随机打乱、放完再重开一轮）。
  void _toggleShuffle() {
    final current = _player.value?.shuffle ?? false;
    _runPlayerAction(() => playerSetShuffle(shuffle: !current));
  }

  /// 打开全屏播放界面。
  ///
  /// 页面本身不持有播放状态：把同一个快照通知器与操作回调传进去，
  /// 于是它与底部播放条永远显示同一个状态、点哪边的按钮都算数。
  void _openPlayer() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(
          player: _player,
          trackById: _trackById,
          onToggle: () => _runPlayerAction(playerToggle, ensureService: true),
          onNext: () => _runPlayerAction(playerNext, ensureService: true),
          onPrevious: () =>
              _runPlayerAction(playerPrevious, ensureService: true),
          onSeek: _seekTo,
          onCycleRepeat: _cycleRepeat,
          onToggleShuffle: _toggleShuffle,
          sleepTimer: _sleepTimer,
        ),
      ),
    );
  }

  /// 按 id 在当前列表里找曲目（底部播放条显示标题用）。
  ///
  /// 列表被搜索过滤后可能找不到正在播放的那首，此时退回缓存的那一份。
  Track? _trackById(int? id) {
    if (id == null || id <= 0) return null;
    final found = _lookupTrack(id);
    if (found != null) return found;
    return id == _playingTrackId ? _playingTrack : null;
  }

  Track? _lookupTrack(int id) {
    for (final track in _tracks) {
      if (track.id == id) return track;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (_hasAccess == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_hasAccess == false) {
      return _PermissionPage(onGranted: _bootstrap);
    }
    if (_error != null) {
      return _ErrorPage(message: _error!, onRetry: _bootstrap);
    }
    return Scaffold(
      // 左侧抽屉：导航 + 播放列表管理。
      // 顶栏的汉堡按钮由 AppBar 自动生成（有 drawer 时默认就是 DrawerButton）。
      drawer: AppDrawer(
        view: _view,
        onSelectView: _selectView,
        playlistId: _playlistId,
        onSelectPlaylist: _openPlaylist,
        api: widget.playlistApi,
      ),
      appBar: AppBar(
        title: _viewTitle(),
        actions: _appBarActions(),
      ),
      body: switch (_view) {
        HomeView.library => _buildLibraryBody(),
        HomeView.myMusic => MyMusicView(
          tracks: _allTracks ?? const <Track>[],
          player: _player,
          onPlay: _playTracks,
          loading: _allTracks == null,
        ),
        HomeView.queue => QueueView(
          queue: _queue.entries,
          player: _player,
          trackById: _trackById,
          onJump: _jumpTo,
        ),
      },
      // 底部播放条固定在屏幕下边缘，三个视图共用同一个（切视图不断音、状态不失同步）
      bottomNavigationBar: ValueListenableBuilder<PlayerSnapshot?>(
        valueListenable: _player,
        builder: (context, snapshot, _) => NowPlayingBar(
          snapshot: snapshot,
          track: _trackById(snapshot?.trackId),
          // 这三个都可能让声音响起来：顺手确认前台服务在跑。
          onToggle: () => _runPlayerAction(playerToggle, ensureService: true),
          onNext: () => _runPlayerAction(playerNext, ensureService: true),
          onPrevious: () => _runPlayerAction(playerPrevious, ensureService: true),
          onSeek: _seekTo,
          onCycleRepeat: _cycleRepeat,
          onToggleShuffle: _toggleShuffle,
          onOpenPlayer: _openPlayer,
        ),
      ),
    );
  }

  /// 主页（曲库）的内容：统计 + 搜索 + 曲目列表。
  Widget _buildLibraryBody() {
    return Column(
      children: [
        _StatsBar(stats: _stats, rootCount: _roots.length),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: TextField(
            controller: _search,
            onChanged: (_) => _reload(),
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search),
              hintText: '搜索标题 / 艺术家 / 专辑',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        Expanded(
          child: ValueListenableBuilder<PlayerSnapshot?>(
            valueListenable: _player,
            builder: (context, snapshot, _) => _TrackList(
              tracks: _tracks,
              emptyHint: _emptyHint(),
              playingId: snapshot?.trackId ?? 0,
              // 正在播放的那首在列表里会被标出来
              playingState: snapshot?.state,
              onPlay: _playAt,
              // 长按 → 添加到播放列表
              onLongPress: _addToPlaylist,
            ),
          ),
        ),
      ],
    );
  }

  /// 主页不显示标题（图片里就是只有汉堡按钮）；
  /// 另外两个视图用标题告诉用户「现在在哪」。
  Widget? _viewTitle() {
    switch (_view) {
      case HomeView.library:
        return null;
      case HomeView.myMusic:
        return const Text('我的音乐');
      case HomeView.queue:
        return const Text('队列');
    }
  }

  /// 扫描入口只在曲库页有用；切到别的视图时藏起来，省得在专辑页误点全量扫描。
  List<Widget> _appBarActions() {
    if (_view != HomeView.library) return const <Widget>[];
    return [
      IconButton(
        tooltip: '增量扫描（只解析变化的文件）',
        onPressed: _busy ? null : () => _scan(full: false),
        icon: const Icon(Icons.refresh),
      ),
      IconButton(
        tooltip: '全量扫描（重新解析所有文件）',
        onPressed: _busy ? null : () => _scan(full: true),
        icon: const Icon(Icons.library_music),
      ),
    ];
  }

  String _emptyHint() => _roots.isEmpty
      ? '没有找到可扫描的音乐目录。\n把你的音乐放进 /storage/emulated/0/Music 后回来重试。'
      : '曲库还是空的。点右下角“全量扫描”开始建立索引。';
}

/// 没有存储权限时的引导页。
class _PermissionPage extends StatelessWidget {
  const _PermissionPage({required this.onGranted});

  final Future<void> Function() onGranted;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(kAppTitle)),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.folder_off_outlined, size: 48),
            const SizedBox(height: 16),
            Text('需要“所有文件访问”权限', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            const Text(
              '播放器要直接读取你存储里的音乐文件（解析标签与内嵌封面），因此需要该权限。\n\n'
              '它只用于扫描本地音乐；本应用不联网，也不上传任何数据。',
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: StorageAccess.request,
              icon: const Icon(Icons.settings),
              label: const Text('去授权'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => onGranted(),
              child: const Text('已授权，重新检查'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorPage extends StatelessWidget {
  const _ErrorPage({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(kAppTitle)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: () => onRetry(), child: const Text('重试')),
            ],
          ),
        ),
      ),
    );
  }
}

/// 顶部统计条：曲库概况 + 扫描来源目录数量。
class _StatsBar extends StatelessWidget {
  const _StatsBar({required this.stats, required this.rootCount});

  final Stats? stats;
  final int rootCount;

  @override
  Widget build(BuildContext context) {
    final stats = this.stats;
    final summary = stats == null
        ? '正在读取曲库…'
        : '${stats.trackCount} 首 · ${stats.albumCount} 张专辑 · '
              '${stats.artistCount} 位艺术家 · '
              '${formatDurationLong(stats.totalDurationMs)} · '
              '${formatSize(stats.totalSizeBytes)}';
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Text(
        '$summary\n扫描目录：$rootCount 个',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

class _TrackList extends StatelessWidget {
  const _TrackList({
    required this.tracks,
    required this.emptyHint,
    required this.playingId,
    required this.onPlay,
    this.playingState,
    this.onLongPress,
  });

  final List<Track> tracks;
  final String emptyHint;

  /// 正在播放的曲目 id（`0` 表示当前没有播放项）。
  final int playingId;

  /// 播放状态，用来区分「在播」和「暂停」。
  final PlayerState? playingState;

  final ValueChanged<int> onPlay;

  /// 长按某一首（曲库页用来弹出「添加到播放列表」）。
  final ValueChanged<Track>? onLongPress;

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(emptyHint, textAlign: TextAlign.center),
        ),
      );
    }
    return ListView.builder(
      itemCount: tracks.length,
      itemBuilder: (context, index) {
        final track = tracks[index];
        final isPlaying = track.id == playingId;
        return TrackTile(
          track: track,
          playing: isPlaying,
          paused: isPlaying && playingState == PlayerState.paused,
          // 点哪首就从哪首开始播：整个列表就是播放队列
          onTap: () => onPlay(index),
          onLongPress: onLongPress == null
              ? null
              : () => onLongPress!(track),
        );
      },
    );
  }
}

// 曲目行已抽到 `track_tile.dart`（`TrackTile`）：曲库页、播放列表页、队列页共用，
// 长按「添加到播放列表」也由它透出 `onLongPress`。


/// 毫秒 → `m:ss`。与核心的约定一致：`0` 表示时长未知，显示 `--:--`。
/// 已搬到 `format.dart`：底部播放条、播放界面、播放列表页都要用。

