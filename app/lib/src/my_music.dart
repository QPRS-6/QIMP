import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:musicplayer/src/format.dart';
import 'package:musicplayer/src/rust/api/library.dart';
import 'package:musicplayer/src/rust/api/player.dart';
import 'package:musicplayer/src/track_tile.dart';

/// 一张专辑（由曲目聚合而来，见 [groupAlbums]）。
class AlbumGroup {
  const AlbumGroup({
    required this.name,
    required this.artist,
    required this.tracks,
  });

  final String name;
  final String artist;
  final List<Track> tracks;

  int get trackCount => tracks.length;
  int get durationMs =>
      tracks.fold(0, (sum, track) => sum + track.durationMs);
}

/// 一位艺术家（由曲目聚合而来，见 [groupArtists]）。
class ArtistGroup {
  const ArtistGroup({
    required this.name,
    required this.tracks,
    required this.albumCount,
  });

  final String name;
  final List<Track> tracks;

  /// 名下不同专辑的数量（空专辑名不计）。
  final int albumCount;

  int get trackCount => tracks.length;
}

/// 未知专辑 / 未知艺术家：界面上总得有个落脚的地方。
const String kUnknownAlbum = '未知专辑';
const String kUnknownArtist = '未知艺术家';

/// 按专辑聚合。
///
/// 归属规则和 core 的 `Track::album_key` 保持一致：专辑名不能为空，
/// 专辑艺术家缺省时退到艺术家，再缺省是「未知艺术家」。这样界面上看到的归属，
/// 和将来交给 SQL 聚合（`list_albums`）算出来的不会对不上。
List<AlbumGroup> groupAlbums(List<Track> tracks) {
  final buckets = <String, List<Track>>{};
  final labels = <String, ({String name, String artist})>{};
  for (final track in tracks) {
    final album = track.album?.trim() ?? '';
    final name = album.isEmpty ? kUnknownAlbum : album;
    final artist = _firstNonEmpty(<String?>[
      track.albumArtist,
      track.artist,
      kUnknownArtist,
    ]);
    final key = '$name\u0000$artist';
    buckets.putIfAbsent(key, () => <Track>[]).add(track);
    labels[key] = (name: name, artist: artist);
  }
  final groups = <AlbumGroup>[
    for (final entry in buckets.entries)
      AlbumGroup(
        name: labels[entry.key]!.name,
        artist: labels[entry.key]!.artist,
        tracks: sortForAlbum(entry.value),
      ),
  ];
  groups.sort((a, b) => _compareNames(a.name, b.name));
  return groups;
}

/// 按艺术家聚合。
List<ArtistGroup> groupArtists(List<Track> tracks) {
  final buckets = <String, List<Track>>{};
  for (final track in tracks) {
    final name = _firstNonEmpty(<String?>[track.artist, kUnknownArtist]);
    buckets.putIfAbsent(name, () => <Track>[]).add(track);
  }
  final groups = <ArtistGroup>[
    for (final entry in buckets.entries)
      ArtistGroup(
        name: entry.key,
        tracks: sortForAlbum(entry.value),
        albumCount: entry.value
            .map((track) => track.album?.trim() ?? '')
            .where((album) => album.isNotEmpty)
            .toSet()
            .length,
      ),
  ];
  groups.sort((a, b) => _compareNames(a.name, b.name));
  return groups;
}

/// 专辑/艺术家内部的顺序：碟号 → 轨号 → 标题。
///
/// 曲库页是按用户选的方式排序的（默认路径），进了专辑得按唱片本身的顺序，
/// 否则「第 2 首」会排到「第 10 首」后面。
List<Track> sortForAlbum(List<Track> tracks) {
  final sorted = List<Track>.of(tracks);
  sorted.sort((a, b) {
    final disc = (a.discNo ?? 0).compareTo(b.discNo ?? 0);
    if (disc != 0) return disc;
    final no = (a.trackNo ?? 0).compareTo(b.trackNo ?? 0);
    if (no != 0) return no;
    return _compareNames(_titleOf(a), _titleOf(b));
  });
  return sorted;
}

String _titleOf(Track track) => track.title.trim();

String _firstNonEmpty(List<String?> values) {
  for (final value in values) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isNotEmpty) return trimmed;
  }
  return kUnknownArtist;
}

/// 大小写不敏感的名字比较（中文按码位，和 SQLite 的 NOCASE 行为接近）。
int _compareNames(String a, String b) =>
    a.toLowerCase().compareTo(b.toLowerCase());

/// 专辑/艺术家行右侧的副标题：N 首 · 时长。
String groupSubtitle(int trackCount, int durationMs) =>
    '$trackCount 首 · ${formatDurationLong(durationMs)}';

/// 「我的音乐」：按专辑 / 艺术家浏览。
///
/// 分组在 Dart 侧做（输入是曲库页已经加载好的整份曲目列表）：
/// 曲库规模在几千首这个量级时一次 O(n) 分组比多跑几条 SQL 更省事，
/// 也让这个页面可以纯函数测试。真到几万首再切到 core 的 `list_albums`
/// / `list_artists`（FFI 早就暴露了）。
class MyMusicView extends StatelessWidget {
  const MyMusicView({
    super.key,
    required this.tracks,
    required this.player,
    required this.onPlay,
    this.loading = false,
  });

  /// 整个曲库（不含搜索过滤）。
  final List<Track> tracks;

  /// 播放状态快照，用来高亮正在播放的那首。
  final ValueListenable<PlayerSnapshot?> player;

  /// 播放一组曲目（从第 `index` 首开始）。
  final void Function(List<Track> tracks, int index) onPlay;

  /// 曲库还在加载中（首屏刚起来时）。
  final bool loading;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (tracks.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('曲库里还没有歌。回到「主页」扫一遍本地目录。', textAlign: TextAlign.center),
        ),
      );
    }
    final albums = groupAlbums(tracks);
    final artists = groupArtists(tracks);
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(tabs: [Tab(text: '专辑'), Tab(text: '艺术家')]),
          Expanded(
            child: TabBarView(
              children: [
                _GroupsTab(
                  groups: [
                    for (final album in albums)
                      (
                        title: album.name,
                        subtitle:
                            '${album.artist} · ${groupSubtitle(album.trackCount, album.durationMs)}',
                        icon: Icons.album_outlined,
                        tracks: album.tracks,
                      ),
                  ],
                  player: player,
                  onPlay: onPlay,
                ),
                _GroupsTab(
                  groups: [
                    for (final artist in artists)
                      (
                        title: artist.name,
                        subtitle:
                            '${artist.trackCount} 首 · ${artist.albumCount} 张专辑',
                        icon: Icons.person_outline,
                        tracks: artist.tracks,
                      ),
                  ],
                  player: player,
                  onPlay: onPlay,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 一列「分组」（专辑或艺术家），点进去是该组的曲目。
class _GroupsTab extends StatelessWidget {
  const _GroupsTab({
    required this.groups,
    required this.player,
    required this.onPlay,
  });

  final List<({String title, String subtitle, IconData icon, List<Track> tracks})>
  groups;
  final ValueListenable<PlayerSnapshot?> player;
  final void Function(List<Track> tracks, int index) onPlay;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: groups.length,
      itemBuilder: (context, index) {
        final group = groups[index];
        return ListTile(
          leading: Icon(group.icon),
          title: Text(group.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            group.subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => GroupTracksPage(
                title: group.title,
                subtitle: group.subtitle,
                tracks: group.tracks,
                player: player,
                onPlay: onPlay,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 某张专辑 / 某位艺术家的曲目页。
///
/// 点一首就以这一组为队列开始播（和曲库页、播放列表页一个规则）。
class GroupTracksPage extends StatelessWidget {
  const GroupTracksPage({
    super.key,
    required this.title,
    required this.subtitle,
    required this.tracks,
    required this.player,
    required this.onPlay,
  });

  final String title;
  final String subtitle;
  final List<Track> tracks;
  final ValueListenable<PlayerSnapshot?> player;
  final void Function(List<Track> tracks, int index) onPlay;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                subtitle,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
          Expanded(
            child: ValueListenableBuilder<PlayerSnapshot?>(
              valueListenable: player,
              builder: (context, snapshot, _) {
                final playingId = snapshot?.trackId ?? 0;
                return ListView.builder(
                  itemCount: tracks.length,
                  itemBuilder: (context, index) {
                    final track = tracks[index];
                    final isPlaying = track.id == playingId;
                    return TrackTile(
                      track: track,
                      playing: isPlaying,
                      paused:
                          isPlaying && snapshot?.state == PlayerState.paused,
                      onTap: () => onPlay(tracks, index),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
