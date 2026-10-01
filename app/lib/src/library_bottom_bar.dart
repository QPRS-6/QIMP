import 'package:flutter/material.dart';
import 'package:musicplayer/src/format.dart';
import 'package:musicplayer/src/rust/api/library.dart';

/// 主页最下面那一条：一排操作按钮 + 一行统计。
///
/// 样式照参考图：图标一行（多选 / 添加歌曲 / 更多），下面一行
/// 「452 / 27:27:36 / 9.75 GB」（曲目数 / 总时长 / 总大小）。
/// 顶栏原来那两个扫描按钮收进了「更多」里，搜索框不动。
///
/// 多选模式下换成选择工具条：多少首已选、全选、两个删除动作、退出。
/// 这一条自己不认识曲库（没有 FFI、没有状态），动作全走回调，
/// 所以宿主机上不用起真曲库也能把它验清楚。
class LibraryBottomBar extends StatelessWidget {
  const LibraryBottomBar({
    super.key,
    required this.stats,
    required this.selecting,
    required this.selectedCount,
    required this.totalCount,
    required this.onToggleSelect,
    required this.onAddSongs,
    required this.onScanIncremental,
    required this.onScanFull,
    required this.onSelectAll,
    required this.onRemoveFromLibrary,
    required this.onDeleteFromStorage,
  });

  /// 曲库统计；还没读出来时为 `null`（显示“正在读取曲库…”）。
  final Stats? stats;

  /// 是否处于多选模式。
  final bool selecting;

  /// 已选中的数量。
  final int selectedCount;

  /// 当前列表里的总数（决定「全选」还是「取消全选」）。
  final int totalCount;

  /// 进 / 出多选模式。
  final VoidCallback onToggleSelect;

  /// 「＋ 添加歌曲」：把扫到但还没入库的歌挑进来。
  final VoidCallback onAddSongs;

  /// 「更多 → 增量扫描」。
  final VoidCallback onScanIncremental;

  /// 「更多 → 全量扫描」。
  final VoidCallback onScanFull;

  /// 全选 / 取消全选。
  final VoidCallback onSelectAll;

  /// 把选中的歌移出曲库（文件还在）。
  final VoidCallback onRemoveFromLibrary;

  /// 把选中的歌从储存里删掉（文件一起没）。
  final VoidCallback onDeleteFromStorage;

  bool get _allSelected => totalCount > 0 && selectedCount >= totalCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Divider(height: 1),
            SizedBox(
              height: 48,
              child: selecting ? _buildSelectionRow() : _buildActionRow(),
            ),
            _buildSummary(theme),
          ],
        ),
      ),
    );
  }

  /// 平时那一行：多选 / 添加歌曲 / 更多。
  Widget _buildActionRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(
          tooltip: '多选',
          onPressed: onToggleSelect,
          icon: const Icon(Icons.checklist),
        ),
        IconButton(
          tooltip: '添加歌曲（从扫描到的文件里挑）',
          onPressed: onAddSongs,
          icon: const Icon(Icons.add_circle),
        ),
        PopupMenuButton<_ScanAction>(
          tooltip: '更多',
          onSelected: (action) => switch (action) {
            _ScanAction.incremental => onScanIncremental(),
            _ScanAction.full => onScanFull(),
          },
          itemBuilder: (context) => const [
            PopupMenuItem(
              value: _ScanAction.incremental,
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.refresh),
                title: Text('增量扫描'),
                subtitle: Text('只解析变化的文件'),
              ),
            ),
            PopupMenuItem(
              value: _ScanAction.full,
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.library_music),
                title: Text('全量扫描'),
                subtitle: Text('重新解析所有文件'),
              ),
            ),
          ],
          icon: const Icon(Icons.more_vert),
        ),
      ],
    );
  }

  /// 多选时那一行。删除类动作只有在选了东西之后才可点。
  Widget _buildSelectionRow() {
    final hasSelection = selectedCount > 0;
    return Row(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(left: 16),
            child: Text('已选 $selectedCount 首'),
          ),
        ),
        TextButton(
          onPressed: onSelectAll,
          child: Text(_allSelected ? '取消全选' : '全选'),
        ),
        IconButton(
          tooltip: '从库中删除',
          onPressed: hasSelection ? onRemoveFromLibrary : null,
          icon: const Icon(Icons.playlist_remove),
        ),
        IconButton(
          tooltip: '从储存中删除',
          onPressed: hasSelection ? onDeleteFromStorage : null,
          icon: const Icon(Icons.delete_forever),
        ),
        IconButton(
          tooltip: '退出多选',
          onPressed: onToggleSelect,
          icon: const Icon(Icons.close),
        ),
      ],
    );
  }

  /// 底部那行数字：曲目数 / 总时长 / 总大小（照参考图的排法）。
  Widget _buildSummary(ThemeData theme) {
    final stats = this.stats;
    final text = stats == null
        ? '正在读取曲库…'
        : '${stats.trackCount} / ${formatDurationLong(stats.totalDurationMs)} '
              '/ ${formatSize(stats.totalSizeBytes)}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall,
      ),
    );
  }
}

/// 「更多」菜单里的两项：原来的两个顶栏扫描按钮。
enum _ScanAction { incremental, full }
