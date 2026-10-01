import 'package:flutter/material.dart';
import 'package:musicplayer/src/add_to_playlist.dart';
import 'package:musicplayer/src/format.dart';
import 'package:musicplayer/src/library_api.dart';
import 'package:musicplayer/src/library_dialogs.dart';
import 'package:musicplayer/src/playlist_api.dart';
import 'package:musicplayer/src/rust/api/library.dart';

/// 长按曲目后的动作表做完了，结果是什么。
///
/// `changed`：曲库动了，界面得重读列表与统计；
/// `deletedIds`：从储存里删掉的曲目（可能正是正在放的那一首，界面要据此停掉播放）。
typedef TrackActionResult = ({bool changed, List<int> deletedIds});

/// 长按曲目后弹出的动作：加入播放列表 / 从库中删除 / 从储存中删除。
///
/// 后两个是「音乐库管理」这一步的要求：以前长按只能加进播放列表，不想要的歌
/// 却怎么都弄不走。两者刻意分开——
/// 「从库中删除」只是清掉入库标记（文件、索引都留着，还能从「＋ 添加歌曲」找回来），
/// 「从储存中删除」才真的动文件，所以它必须再过一道确认。
Future<TrackActionResult> showTrackActions(
  BuildContext context, {
  required Track track,
  LibraryApi libraryApi = const LibraryApi(),
  PlaylistApi playlistApi = const PlaylistApi(),
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final action = await showModalBottomSheet<_TrackAction>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            dense: true,
            leading: const Icon(Icons.music_note),
            title: Text(
              displayTitle(track),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              track.artist?.isNotEmpty ?? false
                  ? track.artist!
                  : track.path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.playlist_add),
            title: const Text('添加到播放列表'),
            onTap: () =>
                Navigator.of(sheetContext).pop(_TrackAction.addToPlaylist),
          ),
          ListTile(
            leading: const Icon(Icons.playlist_remove),
            title: const Text('从库中删除'),
            subtitle: const Text('只是不在曲库里显示，文件还在'),
            onTap: () =>
                Navigator.of(sheetContext).pop(_TrackAction.removeFromLibrary),
          ),
          ListTile(
            leading: const Icon(Icons.delete_forever),
            title: const Text('从储存中删除'),
            subtitle: const Text('连文件一起删掉，不能恢复'),
            onTap: () =>
                Navigator.of(sheetContext).pop(_TrackAction.deleteFromStorage),
          ),
        ],
      ),
    ),
  );
  if (action == null) return (changed: false, deletedIds: const <int>[]);
  // 下面几件事都要再用一次 context（弹面板 / 弹确认框），而上面已经 await 过一次：
  // 先确认它还在树上。抽到 switch 外面，两个分支共享同一条保险。
  if (!context.mounted) return (changed: false, deletedIds: const <int>[]);

  switch (action) {
    case _TrackAction.addToPlaylist:
      // 加入播放列表不改曲库：面板自己会提示成功与否，界面不用重读。
      await showAddToPlaylist(context, track: track, api: playlistApi);
      return (changed: false, deletedIds: const <int>[]);

    case _TrackAction.removeFromLibrary:
      try {
        libraryApi.remove(<int>[track.id]);
        messenger.showSnackBar(
          const SnackBar(content: Text('已从曲库移出，文件还在')),
        );
      } catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('移出失败：$e')));
      }
      return (changed: true, deletedIds: const <int>[]);

    case _TrackAction.deleteFromStorage:
      final ok = await confirmDeleteFromStorage(
        context,
        count: 1,
        title: displayTitle(track),
      );
      if (!ok) return (changed: false, deletedIds: const <int>[]);
      final deleted = await deleteTracksFromStorage(
        messenger,
        libraryApi,
        <int>[track.id],
      );
      return (changed: true, deletedIds: deleted);
  }
}

/// 真正执行「从储存中删除」，并把结果说给用户听。
///
/// 抽出来是因为长按（一首）与多选（一批）走的是同一条路：确认之后调用这里。
/// 失败明细照实报，别把“删了一半”说成“删好了”。
///
/// 返回的是**尝试删掉的那些 id**（界面拿它判断正在放的那首是不是已经没了）。
Future<List<int>> deleteTracksFromStorage(
  ScaffoldMessengerState messenger,
  LibraryApi libraryApi,
  List<int> trackIds,
) async {
  try {
    final summary = await libraryApi.deleteFiles(trackIds);
    final parts = <String>[
      '已删除 ${summary.deleted} 个文件',
      if (summary.failed.isNotEmpty) '${summary.failed.length} 个没删掉',
    ];
    messenger.showSnackBar(SnackBar(content: Text(parts.join('，'))));
    return trackIds;
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('删除失败：$e')));
    return const <int>[];
  }
}

/// 面板里的三件事。
enum _TrackAction { addToPlaylist, removeFromLibrary, deleteFromStorage }
