import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/src/my_music.dart';
import 'package:musicplayer/src/rust/api/library.dart';

/// 分组是纯函数，最容易错的是「归属键」和排序（碟号 / 轨号），单独测。
Track track({
  required int id,
  String title = 'T',
  String? artist = 'A',
  String? album = 'Al',
  String? albumArtist,
  int? trackNo,
  int? discNo,
  int durationMs = 1000,
}) => Track(
  id: id,
  path: '/m/$id.mp3',
  title: title,
  artist: artist,
  album: album,
  albumArtist: albumArtist,
  trackNo: trackNo,
  discNo: discNo,
  durationMs: durationMs,
  sizeBytes: 1,
  modifiedAt: 0,
  hasCover: false,
  addedAt: 0,
);

void main() {
  group('groupAlbums', () {
    test('同专辑同专辑艺术家归到一起，并累加时长', () {
      final groups = groupAlbums([
        track(id: 1, album: 'Kid A', albumArtist: 'Radiohead', durationMs: 1000),
        track(id: 2, album: 'Kid A', albumArtist: 'Radiohead', durationMs: 2000),
        track(id: 3, album: 'Amnesiac', albumArtist: 'Radiohead'),
      ]);

      expect(groups.map((g) => g.name), ['Amnesiac', 'Kid A']);
      final kidA = groups.firstWhere((g) => g.name == 'Kid A');
      expect(kidA.artist, 'Radiohead');
      expect(kidA.trackCount, 2);
      expect(kidA.durationMs, 3000);
    });

    test('专辑名相同的不同艺术家算两张', () {
      final groups = groupAlbums([
        track(id: 1, album: 'Greatest Hits', artist: 'A'),
        track(id: 2, album: 'Greatest Hits', artist: 'B'),
      ]);
      expect(groups.length, 2);
    });

    test('专辑艺术家优先于艺术家', () {
      final groups = groupAlbums([
        track(id: 1, album: 'X', artist: 'Solo', albumArtist: 'Various'),
      ]);
      expect(groups.single.artist, 'Various');
    });

    test('没有专辑名的归到「未知专辑」', () {
      final groups = groupAlbums([track(id: 1, album: null)]);
      expect(groups.single.name, kUnknownAlbum);
    });

    test('专辑名只有空白也算没有', () {
      final groups = groupAlbums([track(id: 1, album: '   ')]);
      expect(groups.single.name, kUnknownAlbum);
    });
  });

  group('groupArtists', () {
    test('按艺术家聚合并数出专辑数（空专辑不计）', () {
      final groups = groupArtists([
        track(id: 1, artist: 'Radiohead', album: 'Kid A'),
        track(id: 2, artist: 'Radiohead', album: 'Amnesiac'),
        track(id: 3, artist: 'Radiohead', album: null),
        track(id: 4, artist: 'Portishead', album: 'Dummy'),
      ]);

      final radiohead = groups.firstWhere((g) => g.name == 'Radiohead');
      expect(radiohead.trackCount, 3);
      expect(radiohead.albumCount, 2);
      expect(groups.first.name, 'Portishead');
    });

    test('没有艺术家名的归到「未知艺术家」', () {
      expect(groupArtists([track(id: 1, artist: null)]).single.name, kUnknownArtist);
    });
  });

  group('sortForAlbum', () {
    test('碟号 → 轨号 → 标题', () {
      final sorted = sortForAlbum([
        track(id: 1, title: 'b', trackNo: 2),
        track(id: 2, title: 'a', trackNo: 10),
        track(id: 3, title: 'no-number'),
        track(id: 4, title: 'disc2', trackNo: 1, discNo: 2),
      ]);
      // 碟号缺省视作 0：没轨号的排最前，然后 2 < 10；第二张碟最后。
      expect(sorted.map((t) => t.id), [3, 1, 2, 4]);
    });

    test('同轨号时按标题，且不改动入参', () {
      final input = [track(id: 1, title: 'b'), track(id: 2, title: 'a')];
      final sorted = sortForAlbum(input);
      expect(sorted.map((t) => t.id), [2, 1]);
      expect(input.map((t) => t.id), [1, 2], reason: '不该就地排序调用方的列表');
    });
  });
}
