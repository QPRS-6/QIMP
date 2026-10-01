import 'package:flutter/material.dart';
import 'package:musicplayer/src/format.dart';
import 'package:musicplayer/src/library_api.dart';
import 'package:musicplayer/src/rust/api/library.dart';

/// 弹出「添加歌曲」：把扫到、但还没进曲库的歌挑进来。
///
/// 返回真正加进曲库的条数（`0` = 取消或什么都没加），调用方据此决定要不要刷新列表。
/// 曲库是**用户自己挑出来的**，所以这个入口不是装饰：扫描只建索引，不会自动入库，
/// 没有它，扫到的歌就永远进不来。
Future<int> showAddSongs(
  BuildContext context, {
  LibraryApi api = const LibraryApi(),
}) async {
  final messenger = ScaffoldMessenger.of(context);

  final List<Track> candidates;
  try {
    candidates = api.pending();
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('读不出待入库的歌：$e')));
    return 0;
  }
  if (candidates.isEmpty) {
    messenger.showSnackBar(
      const SnackBar(content: Text('没有待入库的歌。新下载的音乐可以先在「更多」里扫描一下。')),
    );
    return 0;
  }

  final picked = await showModalBottomSheet<List<int>>(
    context: context,
    // 自己控高：默认那一档只有屏幕的 9/16，而且高度会随内容伸缩（见「队列」弹窗）。
    isScrollControlled: true,
    builder: (sheetContext) => SizedBox(
      height: MediaQuery.sizeOf(sheetContext).height / 2,
      child: SafeArea(
        top: false,
        child: _AddSongsSheet(candidates: candidates),
      ),
    ),
  );
  if (picked == null || picked.isEmpty) return 0;

  try {
    final added = api.add(picked);
    messenger.showSnackBar(SnackBar(content: Text('已加入曲库 $added 首')));
    return added;
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('加入失败：$e')));
    return 0;
  }
}

/// 待入库面板：多选列表 + 底部「加入曲库」。
///
/// 「全选」放在标题行：一次性把扫到的歌全收进来是很常见的用法（尤其是刚装好、
/// 第一次扫完的时候），但默认**一首都不选**——这个应用不替用户决定。
class _AddSongsSheet extends StatefulWidget {
  const _AddSongsSheet({required this.candidates});

  final List<Track> candidates;

  @override
  State<_AddSongsSheet> createState() => _AddSongsSheetState();
}

class _AddSongsSheetState extends State<_AddSongsSheet> {
  final Set<int> _selected = <int>{};

  bool get _allSelected => _selected.length >= widget.candidates.length;

  void _toggle(int trackId) {
    setState(() {
      if (!_selected.remove(trackId)) _selected.add(trackId);
    });
  }

  void _toggleAll() {
    setState(() {
      if (_allSelected) {
        _selected.clear();
      } else {
        _selected.addAll(widget.candidates.map((track) => track.id));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          dense: true,
          title: const Text('添加歌曲'),
          subtitle: Text('扫描到 ${widget.candidates.length} 首还没进曲库'),
          trailing: TextButton(
            onPressed: _toggleAll,
            child: Text(_allSelected ? '取消全选' : '全选'),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            itemCount: widget.candidates.length,
            itemBuilder: (context, index) {
              final track = widget.candidates[index];
              return CheckboxListTile(
                dense: true,
                value: _selected.contains(track.id),
                onChanged: (_) => _toggle(track.id),
                title: Text(
                  displayTitle(track),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  _subtitleOf(track),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              );
            },
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _selected.isEmpty ? '选几首加进来' : '已选 ${_selected.length} 首',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              FilledButton(
                onPressed: _selected.isEmpty
                    ? null
                    : () => Navigator.of(context).pop(_selected.toList()),
                child: Text('加入曲库（${_selected.length}）'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 副标题：艺术家 / 专辑，都没有时退回文件路径。
  static String _subtitleOf(Track track) {
    final parts = <String>[
      if (track.artist?.isNotEmpty ?? false) track.artist!,
      if (track.album?.isNotEmpty ?? false) track.album!,
    ];
    return parts.isEmpty ? track.path : parts.join(' · ');
  }
}
