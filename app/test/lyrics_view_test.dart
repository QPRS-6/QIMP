// 歌词页的用例：加载中 / 有同步歌词 / 纯文本歌词 / 没有歌词 / 没有在播放。
//
// 页面不碰 FFI：`Lyrics` 直接注入，所以这里跑的都是纯 widget 逻辑。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/src/lyrics_view.dart';
import 'package:musicplayer/src/rust/api/library.dart';

import 'fixtures.dart';

Widget harness({
  bool playing = true,
  Future<Lyrics?>? lyrics,
  int positionMs = 0,
  ValueChanged<int>? onSeek,
  VoidCallback? onBack,
}) => MaterialApp(
  home: Scaffold(
    body: LyricsView(
      // `playing: false` 模拟「没有在播放」这一路。
      track: playing ? fakeTrack() : null,
      lyrics: lyrics,
      positionMs: positionMs,
      onSeek: onSeek ?? (_) {},
      onBack: onBack ?? () {},
    ),
  ),
);

void main() {
  test('期望的 .lrc 路径：把扩展名换成 .lrc，其它一律不动', () {
    expect(
      expectedLrcPath('/storage/emulated/0/Music/test.mp3'),
      '/storage/emulated/0/Music/test.lrc',
    );
    // 文件名里有多个点：只换最后一个。
    expect(expectedLrcPath('/m/01 - a.b.flac'), '/m/01 - a.b.lrc');
    // 没有扩展名 → 直接接一个。
    expect(expectedLrcPath('/m/没有扩展名'), '/m/没有扩展名.lrc');
    // 目录名里有点、文件名没有：不能把目录的点当成扩展名。
    expect(expectedLrcPath('/m/v1.0/song'), '/m/v1.0/song.lrc');
    expect(expectedLrcPath(null), isNull);
    expect(expectedLrcPath(''), isNull);
  });

  testWidgets('歌词还在读的时候显示进度圈', (tester) async {
    final pending = Completer<Lyrics?>();
    await tester.pumpWidget(harness(lyrics: pending.future));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    pending.complete(fakeLyrics(<(int, String)>[(0, '第一句')]));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('第一句'), findsOneWidget);
  });

  testWidgets('纯文本歌词：照着文字显示，不做高亮也不给点', (tester) async {
    var seeked = 0;
    await tester.pumpWidget(
      harness(
        lyrics: Future<Lyrics?>.value(fakePlainLyrics(<String>['第一段', '第二段'])),
        onSeek: (value) => seeked = value,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('第一段'), findsOneWidget);
    expect(find.text('第二段'), findsOneWidget);
    expect(find.byType(ListView), findsNothing, reason: '纯文本不用逐行列表');

    await tester.tap(find.text('第一段'));
    await tester.pumpAndSettle();
    expect(seeked, 0, reason: '没有时间戳就没有可跳的地方');
  });

  testWidgets('没有词时提示该把 .lrc 放在哪儿，并且能回封面', (tester) async {
    var backs = 0;
    await tester.pumpWidget(
      harness(
        lyrics: Future<Lyrics?>.value(null),
        onBack: () => backs += 1,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('这首歌没有歌词'), findsOneWidget);
    expect(find.textContaining('test.lrc'), findsOneWidget);

    await tester.tap(find.byTooltip('回封面（右滑也可以）'));
    expect(backs, 1);
  });

  testWidgets('左上角只有一颗「回封面」：不再标「歌词」，按钮摆在左边', (tester) async {
    await tester.pumpWidget(
      harness(
        lyrics: Future<Lyrics?>.value(fakePlainLyrics(<String>['第一段'])),
      ),
    );
    await tester.pumpAndSettle();

    // 那一行「[歌词图标] 歌词」已经删掉了：整页都是歌词，不用再标一遍。
    expect(find.text('歌词'), findsNothing);
    expect(find.byIcon(Icons.lyrics_outlined), findsNothing);

    // 只剩回封面那一颗，而且在左上角（整页的左边、上面那一条）。
    final page = tester.getRect(find.byType(LyricsView));
    final back = tester.getRect(find.byTooltip('回封面（右滑也可以）'));
    expect(back.center.dx, lessThan(page.center.dx), reason: '按钮在左边');
    expect(back.center.dy, lessThan(page.center.dy), reason: '在最上面那一行');
  });

  testWidgets('没有可回的地方时（平板上那一栏）连那条顶栏都不画', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LyricsView(
            track: fakeTrack(),
            lyrics: Future<Lyrics?>.value(fakePlainLyrics(<String>['第一段'])),
            positionMs: 0,
            onSeek: (_) {},
            onBack: null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('回封面（右滑也可以）'), findsNothing);
    expect(find.byType(IconButton), findsNothing);
    // 少了那一行，歌词自己顶到最上面（那一行有 48 高，正文还有 24 的上边距）。
    final page = tester.getRect(find.byType(LyricsView));
    expect(
      tester.getRect(find.text('第一段')).top,
      lessThan(page.top + 48),
      reason: '顶栏不占位置',
    );
  });

  testWidgets('没有在播放时不装作有歌词', (tester) async {
    await tester.pumpWidget(
      harness(playing: false, lyrics: Future<Lyrics?>.value(null)),
    );
    await tester.pumpAndSettle();

    expect(find.text('没有在播放'), findsOneWidget);
  });

  testWidgets('第一句之前高亮第一句：用户已经看到它了', (tester) async {
    await tester.pumpWidget(
      harness(
        lyrics: Future<Lyrics?>.value(
          fakeLyrics(<(int, String)>[(5_000, '第一句'), (10_000, '第二句')]),
        ),
        positionMs: 0,
      ),
    );
    await tester.pumpAndSettle();

    final theme = Theme.of(tester.element(find.text('第一句')));
    expect(
      tester.widget<Text>(find.text('第一句')).style?.color,
      theme.colorScheme.primary,
    );
  });
}
