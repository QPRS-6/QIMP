import 'package:flutter/material.dart';
import 'package:musicplayer/src/format.dart';
import 'package:musicplayer/src/playlist_api.dart';
import 'package:musicplayer/src/rust/api/library.dart';

/// 长按曲目后弹出的「添加到播放列表」。
///
/// 没有列表时也能用：面板最后一项是「新建播放列表…」，先建再加。
/// 少了这一步，新装的 App 得先去抽屉建列表、再回来长按，来回两趟。
///
/// 面板内部自己管「选列表 / 起名字」两步，所以这里只 `await` 一次——
/// 跨 `await` 碰 `BuildContext` 那类坑（`use_build_context_synchronously`）
/// 自然也就不存在了。
Future<void> showAddToPlaylist(
  BuildContext context, {
  required Track track,
  PlaylistApi api = const PlaylistApi(),
}) async {
  final messenger = ScaffoldMessenger.of(context);

  List<Playlist> lists;
  try {
    lists = api.list();
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('播放列表读不出来：$e')));
    return;
  }

  final result = await showModalBottomSheet<_Result>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _AddToPlaylistSheet(track: track, lists: lists),
  );
  if (result == null) return;

  try {
    final id = result.playlistId ?? api.create(result.newName!);
    final name = result.playlistName ?? result.newName!;
    final added = api.add(id, track.id);
    messenger.showSnackBar(
      SnackBar(
        content: Text(added ? '已加入「$name」' : '「$name」里已经有了'),
      ),
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('加入失败：$e')));
  }
}

/// 面板的结果：加了某个已有列表，或者要新建一个。
///
/// `playlistId` 为空表示「新建」——这时 `newName` 是用户起的名字。
class _Result {
  const _Result.existing({required this.playlistId, required this.playlistName})
    : newName = null;

  const _Result.create({required this.newName})
    : playlistId = null,
      playlistName = null;

  final int? playlistId;
  final String? playlistName;
  final String? newName;
}

/// 选择面板本体：默认列已有列表；点「新建」就切到起名字那一屏。
class _AddToPlaylistSheet extends StatefulWidget {
  const _AddToPlaylistSheet({required this.track, required this.lists});

  final Track track;
  final List<Playlist> lists;

  @override
  State<_AddToPlaylistSheet> createState() => _AddToPlaylistSheetState();
}

class _AddToPlaylistSheetState extends State<_AddToPlaylistSheet> {
  final TextEditingController _name = TextEditingController();
  bool _naming = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submitName() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(_Result.create(newName: name));
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            dense: true,
            leading: const Icon(Icons.music_note),
            title: Text(
              displayTitle(widget.track),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(_naming ? '新建播放列表' : '添加到播放列表'),
          ),
          const Divider(height: 1),
          if (_naming)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _name,
                      autofocus: true,
                      maxLength: 60,
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: '列表名字',
                      ),
                      onSubmitted: (_) => _submitName(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: _submitName,
                    child: const Text('创建并加入'),
                  ),
                ],
              ),
            )
          else ...[
            for (final playlist in widget.lists)
              ListTile(
                leading: const Icon(Icons.queue_music),
                title: Text(playlist.name),
                subtitle: Text('${playlist.trackCount} 首'),
                onTap: () => Navigator.of(context).pop(
                  _Result.existing(
                    playlistId: playlist.id,
                    playlistName: playlist.name,
                  ),
                ),
              ),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('新建播放列表…'),
              onTap: () => setState(() => _naming = true),
            ),
          ],
        ],
      ),
    );
  }
}
