import 'package:flutter/material.dart';
import 'package:musicplayer/src/app_info.dart';
import 'package:musicplayer/src/rust/api/library.dart';
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
      _roots = suggestScanRoots();
      _reload();
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
          Expanded(child: _TrackList(tracks: _tracks, emptyHint: _emptyHint())),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : () => _scan(full: true),
        icon: _busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.library_music),
        label: Text(_busy ? '扫描中…' : '全量扫描'),
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
  const _TrackList({required this.tracks, required this.emptyHint});

  final List<Track> tracks;
  final String emptyHint;

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
      itemBuilder: (context, index) => _TrackTile(track: tracks[index]),
    );
  }
}

class _TrackTile extends StatelessWidget {
  const _TrackTile({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final subtitle = <String>[
      if (track.artist?.isNotEmpty ?? false) track.artist!,
      if (track.album?.isNotEmpty ?? false) track.album!,
      if (track.hasCover) '含封面',
    ].join(' · ');
    return ListTile(
      dense: true,
      leading: const Icon(Icons.music_note),
      title: Text(
        track.title.isEmpty ? track.path.split('/').last : track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
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
