import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:musicplayer/src/playback_service.dart';
import 'package:musicplayer/src/playlist_api.dart';
import 'package:musicplayer/src/playlist_dialogs.dart';
import 'package:musicplayer/src/queue_store.dart';
import 'package:musicplayer/src/rust/api/library.dart';
import 'package:musicplayer/src/rust/api/player.dart';
import 'package:musicplayer/src/track_tile.dart';

/// 一个播放列表的内容页。
///
/// 点一首歌就以「这个列表」为队列开始播放（和曲库页的规则一致：列表即队列）；
/// 右上角进编辑模式后每行多出一个「移出」按钮。
class PlaylistPage extends StatefulWidget {
  const PlaylistPage({
    super.key,
    required this.playlist,
    required this.player,
    required this.queue,
    this.api = const PlaylistApi(),
  });

  final Playlist playlist;

  /// 播放状态快照（与底部播放条同一个通知器，两边永远显示同一状态）。
  final ValueListenable<PlayerSnapshot?> player;

  /// 播放队列镜像：这里换了队列，抽屉的「队列」视图要跟着变。
  final PlayQueueStore queue;

  final PlaylistApi api;

  @override
  State<PlaylistPage> createState() => _PlaylistPageState();
}

class _PlaylistPageState extends State<PlaylistPage> {
  List<Track> _tracks = const <Track>[];
  String? _error;
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    try {
      final tracks = widget.api.tracks(widget.playlist.id);
      setState(() {
        _tracks = tracks;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  /// 从这一首开始放：整个列表就是播放队列。
  void _playAt(int index) {
    PlaybackService.start();
    try {
      setPlayQueue(
        entries: queueEntriesOf(_tracks),
        startAt: index,
        autoplay: true,
      );
      widget.queue.replace(queueEntriesOf(_tracks));
    } catch (e) {
      _toast('无法播放：$e');
    }
  }

  /// 把这一首移出列表。核心按「曲目 id」删，所以不用担心行号与内部下标错位。
  void _remove(Track track) {
    try {
      widget.api.remove(widget.playlist.id, track.id);
      _reload();
    } catch (e) {
      _toast('移出失败：$e');
    }
  }

  Future<void> _rename() async {
    final name = await askPlaylistName(
      context,
      title: '重命名',
      confirm: '保存',
      initial: widget.playlist.name,
    );
    if (name == null || !mounted) return;
    try {
      widget.api.rename(widget.playlist.id, name);
      if (mounted) setState(() {});
      _toast('已改名为「$name」');
    } catch (e) {
      _toast('改名失败：$e');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final playlist = widget.playlist;
    return Scaffold(
      appBar: AppBar(
        title: Text(playlist.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '重命名',
            onPressed: _rename,
            icon: const Icon(Icons.drive_file_rename_outline),
          ),
          IconButton(
            tooltip: _editing ? '完成' : '编辑（把歌移出列表）',
            onPressed: () => setState(() => _editing = !_editing),
            icon: Icon(_editing ? Icons.check : Icons.edit),
          ),
        ],
      ),
      body: ValueListenableBuilder<PlayerSnapshot?>(
        valueListenable: widget.player,
        builder: (context, snapshot, _) => _buildList(snapshot),
      ),
    );
  }

  Widget _buildList(PlayerSnapshot? snapshot) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('列表读不出来：\n$_error', textAlign: TextAlign.center),
        ),
      );
    }
    if (_tracks.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '这个列表还是空的。\n回曲库长按一首歌，选「添加到播放列表」就能加进来。',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final playingId = snapshot?.trackId ?? 0;
    return ListView.builder(
      itemCount: _tracks.length,
      itemBuilder: (context, index) {
        final track = _tracks[index];
        final isPlaying = track.id == playingId;
        return TrackTile(
          track: track,
          playing: isPlaying,
          paused: isPlaying && snapshot?.state == PlayerState.paused,
          onTap: () => _playAt(index),
          trailing: _editing
              ? IconButton(
                  tooltip: '移出列表',
                  onPressed: () => _remove(track),
                  icon: const Icon(Icons.remove_circle_outline),
                )
              : null,
        );
      },
    );
  }
}
