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

/// 某一句是不是高亮的（高亮 = 主题色，见 `lyrics_view` 里那段 `Text` 样式）。
bool highlighted(WidgetTester tester, String text) {
  final finder = find.text(text);
  final theme = Theme.of(tester.element(finder));
  return tester.widget<Text>(finder).style?.color == theme.colorScheme.primary;
}

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

  /// 三条歌词的固定素材。`lyrics` 是同一个 Future：模拟播放中每几百毫秒重建一次。
  Future<Lyrics?> threeLines() => Future<Lyrics?>.value(
    fakeLyrics(<(int, String)>[(5_000, '第一句'), (10_000, '第二句'), (15_000, '第三句')]),
  );

  testWidgets('点哪句哪句亮：跳转落点在那句之前时也算（暂停时位置不会自己追上来）', (tester) async {
    final lyrics = threeLines();
    final seeked = <int>[];
    await tester.pumpWidget(
      harness(lyrics: lyrics, positionMs: 5_000, onSeek: seeked.add),
    );
    await tester.pumpAndSettle();
    expect(highlighted(tester, '第一句'), isTrue);

    // 点第二句（暂停中）：先把跳转报出去。
    await tester.tap(find.text('第二句'));
    await tester.pumpAndSettle();
    expect(seeked, [10_000], reason: '点哪句就跳哪句');

    // 快照回来：跳转只能落到不晚于目标的包上，位置停在这句时间戳**之前**一点点
    // （这里按 mp3 一帧 26ms 量）。暂停时它不会再往前走，高亮必须还是这一句。
    await tester.pumpWidget(
      harness(lyrics: lyrics, positionMs: 9_980, onSeek: seeked.add),
    );
    await tester.pumpAndSettle();
    expect(
      highlighted(tester, '第二句'),
      isTrue,
      reason: '点过的那一句优先，不能因为位置差几十毫秒就亮成上一句',
    );
    expect(highlighted(tester, '第一句'), isFalse);
  });

  testWidgets('点过的那一句只钉到下一句为止：播放走过去之后照旧跟着位置走', (tester) async {
    final lyrics = threeLines();
    await tester.pumpWidget(harness(lyrics: lyrics, positionMs: 5_000));
    await tester.pumpAndSettle();

    await tester.tap(find.text('第二句'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(harness(lyrics: lyrics, positionMs: 9_980));
    await tester.pumpAndSettle();
    expect(highlighted(tester, '第二句'), isTrue);

    // 播过第三句的时间戳：钉子松开，按位置算就该是第三句。
    await tester.pumpWidget(harness(lyrics: lyrics, positionMs: 15_100));
    await tester.pumpAndSettle();
    expect(highlighted(tester, '第三句'), isTrue);
    expect(highlighted(tester, '第二句'), isFalse);
  });

  testWidgets('点完又跳到别处：钉子该松，不能一直亮着点过的那句', (tester) async {
    final lyrics = threeLines();
    await tester.pumpWidget(harness(lyrics: lyrics, positionMs: 5_000));
    await tester.pumpAndSettle();

    await tester.tap(find.text('第二句'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(harness(lyrics: lyrics, positionMs: 9_980));
    await tester.pumpAndSettle();
    expect(highlighted(tester, '第二句'), isTrue);

    // 用进度条拖回 2 秒：离钉住的那句很远，高亮该回到位置上那一句。
    await tester.pumpWidget(harness(lyrics: lyrics, positionMs: 2_000));
    await tester.pumpAndSettle();
    expect(highlighted(tester, '第一句'), isTrue);
    expect(highlighted(tester, '第二句'), isFalse);
  });

  testWidgets('换歌（换了一份歌词）之后钉子失效：下标指的是新歌词里的句子了', (tester) async {
    // 同一个 Future：模拟播放中的多次重建（位置在变，歌词本身没换）。
    final first = threeLines();
    await tester.pumpWidget(harness(lyrics: first, positionMs: 5_000));
    await tester.pumpAndSettle();

    await tester.tap(find.text('第二句'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(harness(lyrics: first, positionMs: 9_980));
    await tester.pumpAndSettle();
    expect(highlighted(tester, '第二句'), isTrue);

    // 换歌：另一份歌词，位置还在 9.98 秒。下标 1 在新歌词里已经是另一句了，
    // 钉子必须先松开，否则会亮错（乙）。
    await tester.pumpWidget(
      harness(
        lyrics: Future<Lyrics?>.value(
          fakeLyrics(<(int, String)>[(5_000, '甲'), (10_000, '乙'), (15_000, '丙')]),
        ),
        positionMs: 9_980,
      ),
    );
    await tester.pumpAndSettle();
    expect(highlighted(tester, '甲'), isTrue, reason: '新歌该按自己的位置算');
    expect(highlighted(tester, '乙'), isFalse);
  });

  // -------------------------------------------------------------------------
  // 逐字歌词（增强型 LRC 的 `<mm:ss.xx>`，解析在 Rust 的 `core::lyric`）
  // -------------------------------------------------------------------------

  /// 一行逐字歌词：`今天 天气 不错`，每段各 500ms。
  Lyrics wordLyrics() => fakeWordLyrics(<(int, List<(int, String)>)>[
    (10_000, <(int, String)>[(10_000, '今天 '), (10_500, '天气 '), (11_000, '不错')]),
  ]);

  /// `karaokeRuns` 的结果摊平成 `(片段, 已唱)` 给人看。
  List<(String, bool)> runsAt(int positionMs) {
    final line = wordLyrics().lines[0];
    return karaokeRuns(line, positionMs);
  }

  test('逐字：还没唱到的字算未唱，唱到的算已唱，词内按字数插值', () {
    expect(
      runsAt(9_999).map((run) => run.$2),
      everyElement(isFalse),
      reason: '这一行还没开始',
    );

    // 第一段（10.0s–10.5s）唱到 40%：`今天 ` 三个字（含词尾空格）里切在第一个字后。
    expect(runsAt(10_200), [('今', true), ('天 ', false), ('天气 ', false), ('不错', false)]);
    expect(
      runsAt(10_500),
      [('今天 ', true), ('天气 ', false), ('不错', false)],
      reason: '正好到下一段：前一段整段算已唱',
    );
    expect(
      runsAt(20_000),
      [('今天 ', true), ('天气 ', true), ('不错', true)],
      reason: '最后一段没有结束时间：一旦开始就整段算已唱',
    );

    // 片段拼起来永远是整行文字，一个字都不多不少。
    for (final positionMs in [0, 10_250, 10_500, 11_200, 99_999]) {
      expect(runsAt(positionMs).map((run) => run.$1).join(), '今天 天气 不错');
    }
  });

  test('逐字：没有逐字时间轴的行不参与逐字渲染，数据对不上时整行高亮', () {
    final plain = fakeLyrics(<(int, String)>[(10_000, '整句没有逐字')]).lines[0];
    expect(karaokeRuns(plain, 10_500), isEmpty, reason: '普通行照旧整行高亮');

    // 坏数据（words 拼出来跟 text 对不上）：宁可整行高亮，也别显示一行拼错的字。
    final broken = LyricLine(
      timeMs: 10_000,
      text: '对不上的文字',
      words: [LyricWord(timeMs: 10_000, text: '别的字')],
    );
    expect(karaokeRuns(broken, 10_500), isEmpty);
  });

  test('逐字：译文那段（words 没覆盖）算未唱', () {
    final line = LyricLine(
      timeMs: 10_000,
      text: '原文\ntranslation',
      words: [LyricWord(timeMs: 10_000, text: '原文')],
    );
    expect(karaokeRuns(line, 11_000), [('原文', true), ('\ntranslation', false)]);
  });

  testWidgets('逐字歌词：当前这一行按已唱 / 未唱分色渲染', (tester) async {
    await tester.pumpWidget(
      harness(lyrics: Future<Lyrics?>.value(wordLyrics()), positionMs: 10_200),
    );
    await tester.pumpAndSettle();

    final rich = tester.widget<Text>(find.byType(Text).first);
    final spans = (rich.textSpan as TextSpan).children!.cast<TextSpan>();
    final theme = Theme.of(tester.element(find.byType(Text).first));

    expect(
      spans.map((span) => span.text).join(),
      '今天 天气 不错',
      reason: '逐字渲染不能改变这一行的文字',
    );
    expect(spans.first.text, '今');
    expect(
      spans.first.style?.color,
      theme.colorScheme.primary,
      reason: '唱到的字用主题色',
    );
    expect(
      spans[1].style?.color,
      isNull,
      reason: '没唱到的字不设颜色，跟着整行的弱化色走',
    );
    expect(rich.style?.color, theme.colorScheme.onSurfaceVariant);
  });

  testWidgets('没有逐字时间轴的行照旧整行高亮，不换成富文本', (tester) async {
    await tester.pumpWidget(
      harness(
        lyrics: Future<Lyrics?>.value(
          fakeLyrics(<(int, String)>[(10_000, '整句没有逐字')]),
        ),
        positionMs: 10_250,
      ),
    );
    await tester.pumpAndSettle();

    final text = tester.widget<Text>(find.text('整句没有逐字'));
    expect(text.textSpan, isNull, reason: '普通行走原来的那条路');
    final theme = Theme.of(tester.element(find.text('整句没有逐字')));
    expect(text.style?.color, theme.colorScheme.primary, reason: '整行高亮');
  });
}
