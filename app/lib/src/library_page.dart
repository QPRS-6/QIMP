import 'dart:async';

// Flutter 的 material 也导出了一个 `RepeatMode`（重复动画用）。
// 这里要用的是播放器的循环模式，所以把 Flutter 那个藏起来，避免歧义。
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:musicplayer/src/app_info.dart';
import 'package:musicplayer/src/now_playing_bar.dart';
import 'package:musicplayer/src/rust/api/library.dart';
import 'package:musicplayer/src/rust/api/player.dart';
import 'package:musicplayer/src/storage.dart';
import 'package:path_provider/path_provider.dart';

/// 曲库页：授权 → 打开数据库 → 扫描 → 列表 / 搜索。
///
/// 流程上区分两种“失败”：
/// - 没有存储权限：给一屏指引，点按钮跳系统设置；
/// - 其它异常：直接显示错误文本，避免用户面对一个白屏。

/// 权限查询的注入点：默认走真实 MethodChannel；测试里可替换成确定性的桩。
typedef AccessProbe = Future<bool> Function();

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, this.accessProbe = StorageAccess.granted});

  /// 返回 `true` 表示已获得存储访问权。
  final AccessProbe accessProbe;

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

  /// 播放状态快照。只让底部播放条监听它，避免每 500ms 重建整个曲目列表。
  final ValueNotifier<PlayerSnapshot?> _player = ValueNotifier<PlayerSnapshot?>(
    null,
  );
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _player.dispose();
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
  void _reload() {
    final query = _search.text.trim();
    _tracks = query.isEmpty
        ? listTracks(sort: SortKey.title, descending: false, limit: 2000)
        : searchTracks(query: query, limit: 500);
    _stats = libraryStats();
    setState(() {});
  }

  Future<void> _scan({required bool full}) async {
    setState(() => _busy = true);
    try {
      final summary = await scanLibrary(
        roots: _roots,
        mode: full ? ScanMode.full : ScanMode.incremental,
      );
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
      _player.value = playerSnapshot();
    } catch (_) {
      // 忽略：下一轮会再试，不值得往界面上抛错误。
    }
  }

  /// 统一的播放操作包装：出错提示用户，结束后刷新一次快照。
  void _runPlayerAction(void Function() action) {
    try {
      action();
    } catch (e) {
      _toast('$e');
    }
    _refreshPlayer();
  }

  /// 从当前列表的第 `index` 首开始播放（列表本身就是播放队列）。
  void _playAt(int index) {
    try {
      setPlayQueue(
        entries: [
          for (final track in _tracks)
            QueueEntry(id: track.id, path: track.path),
        ],
        startAt: index,
        autoplay: true,
      );
    } catch (e) {
      _toast('无法播放：$e');
    }
    _refreshPlayer();
  }

  /// 循环模式：关闭 → 列表循环 → 单曲循环 → 关闭。
  void _cycleRepeat() {
    const order = [RepeatMode.off, RepeatMode.all, RepeatMode.one];
    final current = _player.value?.repeat ?? RepeatMode.off;
    final next = order[(order.indexOf(current) + 1) % order.length];
    _runPlayerAction(() => playerSetRepeat(mode: next));
  }

  /// 按 id 在当前列表里找曲目（底部播放条显示标题用）。
  Track? _trackById(int? id) {
    if (id == null || id <= 0) return null;
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
      appBar: AppBar(
        title: const Text(kAppTitle),
        actions: [
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
        ],
      ),
      body: Column(
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
              ),
            ),
          ),
        ],
      ),
      // 底部播放条固定在屏幕下边缘，FAB 会让位（扫描入口已移到 AppBar）
      bottomNavigationBar: ValueListenableBuilder<PlayerSnapshot?>(
        valueListenable: _player,
        builder: (context, snapshot, _) => NowPlayingBar(
          snapshot: snapshot,
          track: _trackById(snapshot?.trackId),
          onToggle: () => _runPlayerAction(playerToggle),
          onNext: () => _runPlayerAction(playerNext),
          onPrevious: () => _runPlayerAction(playerPrevious),
          onSeek: (positionMs) =>
              _runPlayerAction(() => playerSeek(positionMs: positionMs)),
          onCycleRepeat: _cycleRepeat,
        ),
      ),
    );
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
  });

  final List<Track> tracks;
  final String emptyHint;

  /// 正在播放的曲目 id（`0` 表示当前没有播放项）。
  final int playingId;

  /// 播放状态，用来区分「在播」和「暂停」。
  final PlayerState? playingState;

  final ValueChanged<int> onPlay;

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
        return _TrackTile(
          track: track,
          playing: isPlaying,
          paused: isPlaying && playingState == PlayerState.paused,
          // 点哪首就从哪首开始播：整个列表就是播放队列
          onTap: () => onPlay(index),
        );
      },
    );
  }
}

class _TrackTile extends StatelessWidget {
  const _TrackTile({
    required this.track,
    required this.onTap,
    this.playing = false,
    this.paused = false,
  });

  final Track track;
  final VoidCallback onTap;

  /// 是否是当前播放项。
  final bool playing;

  /// 当前播放项是否处于暂停。
  final bool paused;

  @override
  Widget build(BuildContext context) {
    final subtitle = <String>[
      if (track.artist?.isNotEmpty ?? false) track.artist!,
      if (track.album?.isNotEmpty ?? false) track.album!,
      if (track.hasCover) '含封面',
    ].join(' · ');
    final accent = Theme.of(context).colorScheme.primary;
    return ListTile(
      dense: true,
      onTap: onTap,
      selected: playing,
      leading: Icon(
        playing
            ? (paused ? Icons.pause_circle_outline : Icons.equalizer)
            : Icons.music_note,
        color: playing ? accent : null,
      ),
      title: Text(
        track.title.isEmpty ? track.path.split('/').last : track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: playing ? TextStyle(color: accent) : null,
      ),
      subtitle: Text(
        subtitle.isEmpty ? track.path : subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(formatDuration(track.durationMs)),
    );
  }
}

/// 毫秒 → `m:ss`。与核心的约定一致：`0` 表示时长未知，显示 `--:--`。
String formatDuration(int ms) {
  if (ms <= 0) return '--:--';
  final totalSeconds = (ms / 1000).round();
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

/// 毫秒 → `h:mm:ss`。用于“总时长”这种必然超过一小时的数字。
String formatDurationLong(int ms) {
  if (ms <= 0) return '0:00';
  final totalSeconds = (ms / 1000).round();
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  final mm = minutes.toString().padLeft(2, '0');
  final ss = seconds.toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$mm:$ss' : '$minutes:$ss';
}

/// 字节 → 人类可读（保留一位小数）。
String formatSize(int bytes) {
  const units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return unit == 0
      ? '${value.toInt()} ${units[unit]}'
      : '${value.toStringAsFixed(1)} ${units[unit]}';
}
