import 'package:flutter/material.dart';
import 'package:musicplayer/src/playlist_files.dart';
import 'package:musicplayer/src/rust/api/library.dart';

/// 问一个播放列表的名字。空名字返回 `null`（等于取消）。
///
/// 抽屉和「添加到播放列表」都要问名字，两个地方必须长得一样。
/// 空名字直接不给过：核心那边只会 `trim()`，空串会让列表变成一行空白。
Future<String?> askPlaylistName(
  BuildContext context, {
  required String title,
  required String confirm,
  String initial = '',
}) {
  return showDialog<String>(
    context: context,
    builder: (context) =>
        _NameDialog(title: title, confirm: confirm, initial: initial),
  );
}

/// 起名字的对话框。
///
/// 写成 StatefulWidget 是为了让**它自己**持有并释放 `TextEditingController`：
/// 在 `showDialog` 的 `await` 之后立刻 `dispose()` 会撞上「对话框还在做退场动画，
/// 里面的 TextField 还要用它」——真机上表现为一行报错，测试里直接红。
class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.confirm,
    required this.initial,
  });

  final String title;
  final String confirm;
  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 空名字直接不给过：核心那边只会 `trim()`，空串会让列表变成一行空白。
  void _submit() {
    final name = _controller.text.trim();
    Navigator.of(context).pop(name.isEmpty ? null : name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 60,
        decoration: const InputDecoration(hintText: '列表名字'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.confirm)),
      ],
    );
  }
}

/// 问导出成哪种格式。取消返回 `null`。
///
/// 用 `SimpleDialog` 而不是 `AlertDialog`：两个选项各自带一句说明，
/// 用户不该为了选格式先去查「m3u8 和 xspf 到底差在哪」。
Future<PlaylistExportFormat?> chooseExportFormat(
  BuildContext context, {
  required String playlistName,
}) {
  return showDialog<PlaylistExportFormat>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text('把「$playlistName」导出成'),
      children: [
        for (final format in PlaylistExportFormat.values)
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(format),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.description_outlined),
              title: Text(format.label),
              subtitle: Text(format.description),
            ),
          ),
      ],
    ),
  );
}

/// 删除列表前的确认。
///
/// 空列表直接放行（没什么可丢的）；非空的要把话说清楚：
/// **移出列表不等于删文件**，这是用户最容易误会的点。
Future<bool> confirmDeletePlaylist(
  BuildContext context,
  Playlist playlist,
) async {
  if (playlist.trackCount == 0) return true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('删除「${playlist.name}」？'),
      content: Text(
        '列表里的 ${playlist.trackCount} 首歌会被移出这个列表，音乐文件本身不受影响。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  return ok ?? false;
}
