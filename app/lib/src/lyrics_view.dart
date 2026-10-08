// 歌词页：跟着播放进度高亮当前句，并自动把它滚到中间。
//
// 它不碰 FFI：歌词由播放界面注入（[LyricsLoader]），所以这里跑的是纯 widget 逻辑，
// 测试不需要 Rust 侧在场。纵向滑动留给歌词列表自己滚——封面页那个「上下滑调音量」
// 在这一页让位（见 `player_page` 里的手势分发）。
import 'package:flutter/material.dart';

import 'package:musicplayer/src/rust/api/library.dart';

/// 歌词加载器：默认走 Rust 的 `track_lyrics`（同目录 `.lrc` → 内嵌歌词），
/// 测试里换成确定性的桩。
typedef LyricsLoader = Future<Lyrics?> Function(int trackId);

/// 固定行高（逻辑像素）。
///
/// 固定下来之后「把当前句滚到中间」可以一次算准：不用问每一行的实际高度，
/// 也就不用等一帧才能滚（等一帧会看到明显的“先抖再跳”）。
/// 一条歌词可能有两行（同一时间戳的原文 + 翻译），那种一条占两倍高度。
const double kLyricLineHeight = 44;

/// 点过某一句之后，允许位置比那句时间戳**早**多少毫秒仍算「就是这一句」。
///
/// 为什么需要它：跳转只能落到**不晚于**目标的包上（`SeekMode::Accurate` 的语义，
/// 见 `rust/audio/tests/real_file_seek.rs`：mp3 一帧约 26ms、flac 一块可能上百毫秒），
/// 所以点完那一句之后，位置其实还停在这句时间戳之前一点点。播放时几毫秒就追上来了，
/// 暂停时位置不动——靠位置算出来的高亮就会**一直停在上一句**。
///
/// 取 500ms：比上面几种包的误差都宽，又不至于把顺序播放时的上一句误判成这一句
/// （歌词句与句之间通常隔好几秒）。
const int kLyricPinPreRollMs = 500;

/// 一条歌词要占几行：文本里的换行数 + 1。
///
/// 同一时间戳的原文 + 翻译在 core 里就合成了一条（文本用 `\n` 连接），
/// 所以这里数换行就知道它要占几行格子。
int lyricLineCount(String text) => '\n'.allMatches(text).length + 1;

/// 期望的歌词文件路径，例如 `/storage/.../Music/歌名.lrc`。
///
/// 只给「没有歌词」那句提示用，规则与 Rust 侧一致：**同目录同名 + `.lrc`**。
String? expectedLrcPath(String? trackPath) {
  if (trackPath == null || trackPath.isEmpty) return null;
  final slash = trackPath.lastIndexOf('/');
  final dot = trackPath.lastIndexOf('.');
  // 没有扩展名（或者那个点号在目录名里）时直接接一个 `.lrc`。
  if (dot <= slash) return '$trackPath.lrc';
  return '${trackPath.substring(0, dot)}.lrc';
}

/// 逐字歌词：把一行的文字按当前位置切成 `(片段, 已唱)`。
///
/// 只有**带逐字时间轴**的行（`line.words` 非空，即增强型 LRC 的 `<mm:ss.xx>`）才有
/// 内容；普通行返回空列表，界面照旧整行高亮。
///
/// 几条规则：
/// - 一个词内部按**字数**插值切一刀：逐字时间轴给的是「每个词什么时候开始」，
///   长词（比如一整句英文）不切的话会一秒里猛跳一下；切在 runes 上，
///   别把代理对劈成乱码。词尾那个空格也算一个字，所以它总是这一段里最后才亮的。
/// - 词与词之间的缝隙（还没轮到下一段的那些文字）算未唱。
/// - 拼起来等于 `line.text`：译文那段（合并进来的第二行）没有自己的逐字信息，
///   一律算未唱。
/// - 数据对不上（`words` 拼出来不是 `line.text` 的开头）时返回空列表——
///   宁可整行高亮，也不要显示一行拼错的字。
List<(String, bool)> karaokeRuns(LyricLine line, int positionMs) {
  final words = line.words;
  if (words.isEmpty) return const <(String, bool)>[];
  final wordsText = words.map((word) => word.text).join();
  if (!line.text.startsWith(wordsText)) return const <(String, bool)>[];

  final runs = <(String, bool)>[];
  // 空片段不输出：切在词首/词尾时会切出一个空串，留着只会产生空的 TextSpan。
  void add(String text, bool sung) {
    if (text.isNotEmpty) runs.add((text, sung));
  }

  for (var i = 0; i < words.length; i++) {
    final word = words[i];
    if (positionMs < word.timeMs) {
      add(word.text, false);
      continue;
    }
    // 下一段的开始时间就是这一段的结束；最后一段没有结束时间，整段算已唱。
    final nextStart = i + 1 < words.length ? words[i + 1].timeMs : null;
    if (nextStart == null || positionMs >= nextStart) {
      add(word.text, true);
      continue;
    }
    final span = nextStart - word.timeMs;
    final done = (positionMs - word.timeMs).clamp(0, span);
    final units = word.text.runes.toList();
    final cut = span == 0 ? units.length : (units.length * done / span).round();
    add(String.fromCharCodes(units.take(cut)), true);
    add(String.fromCharCodes(units.skip(cut)), false);
  }

  // 译文（合并进来、`words` 没覆盖的那一段）算未唱。
  add(line.text.substring(wordsText.length), false);
  return runs;
}

/// 歌词页。
///
/// 三件事：带时间轴的高亮 + 自动滚动（点一句能跳过去）、纯文本歌词的静态展示、
/// 以及「没有歌词」时明确告诉用户 `.lrc` 该放在哪儿。
///
/// 左上角只有一颗「回封面」（`onBack` 为 null 时连它都不画，什么也不占）。
class LyricsView extends StatefulWidget {
  const LyricsView({
    super.key,
    required this.track,
    required this.lyrics,
    required this.positionMs,
    required this.onSeek,
    required this.onBack,
  });

  /// 当前曲目；`null` 表示没有在播放。
  final Track? track;

  /// 歌词加载结果；`null` 表示还没开始加载。
  final Future<Lyrics?>? lyrics;

  /// 当前播放位置（毫秒）：决定高亮哪一句。
  final int positionMs;

  /// 点某一句就跳到那儿（毫秒）。
  final ValueChanged<int> onSeek;

  /// 回到封面页（**左上角**那颗按钮，见 [_LyricsViewState._header]）。右滑也能回去，
  /// 见 `player_page`。
  ///
  /// `null` 表示这一栏没有「上一页」可回：平板上歌词常驻右边那一栏，
  /// 跟封面是并排的，没有可回的地方（见 `player_page` 的分栏）——那时整条顶栏都不画。
  final VoidCallback? onBack;

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  final ScrollController _controller = ScrollController();

  /// 上一次高亮的行下标；用来判断「是不是换句了」。
  int? _activeIndex;

  /// 每条歌词占的高度与它的累计偏移（用来把当前句滚到中间）。
  ///
  /// 两行的条目占两倍高度，所以不能再用统一的 `itemExtent`：这里算出来的
  /// 高度会**原样**套在每条上（`SizedBox`），于是偏移量与真实布局永远一致。
  List<double> _heights = const <double>[];
  List<double> _offsets = const <double>[];

  /// 上面两份数据对应的是哪一份歌词（换歌 / 加载完就重算）。
  Lyrics? _measured;

  /// 用户点过的那一句的下标；`null` 表示没有钉住任何一句。
  ///
  /// 见 [kLyricPinPreRollMs]：点完之后位置还停在那句时间戳之前，靠位置算会亮成上一句。
  int? _pinnedIndex;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 平板上那一栏没有可回的地方：`_header` 返回 null，这颗元素干脆不出现
        // （null-aware 元素），不留一条空横条白占地方。
        ?_header(context),
        Expanded(child: _body(context)),
      ],
    );
  }

  /// 左上角那一颗「回封面」。
  ///
  /// 原来这一行是「[歌词图标] 歌词 …… [回封面]」：用户后来说左边那两个字和图标是废话
  /// （整页都是歌词，不用再标一遍），并且「回封面」原来是靠右摆的——**横屏时它正好贴着
  /// 左右两栏的交界**，得跨过大半个屏幕去点。现在标签删掉、按钮搬到左上角，就落在原来
  /// 那个标签的位置上：回上一页的入口本来就该在那儿。
  ///
  /// 位置由 [Align] 钉在左边，**不用 `Row` + `Spacer`**——那样按钮又会跟着右边缘走。
  /// 留一个看得见的返回入口仍然有必要：滑动手势对第一次用的人不可见，也更容易误触。
  ///
  /// [widget.onBack] 为 null（平板上歌词常驻右边那一栏，没有「上一页」可回）时
  /// 整行都不出现：不留一条空横条白占着歌词的地方。
  Widget? _header(BuildContext context) {
    final onBack = widget.onBack;
    if (onBack == null) return null;
    return Align(
      alignment: Alignment.centerLeft,
      // 外面这 8 是让按钮的图标与正文左侧（24）看起来是一条线上的：按钮自己还有
      // 一圈内边距，加起来差不多刚好。
      child: Padding(
        padding: const EdgeInsets.only(left: 8),
        child: IconButton(
          tooltip: '回封面（右滑也可以）',
          onPressed: onBack,
          icon: const Icon(Icons.album_outlined),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final track = widget.track;
    if (track == null) {
      return _hint(context, '没有在播放', null);
    }

    return FutureBuilder<Lyrics?>(
      future: widget.lyrics,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final lyrics = snapshot.data;
        if (lyrics == null || lyrics.lines.isEmpty) {
          return _hint(
            context,
            '这首歌没有歌词',
            '同目录放一个同名的 .lrc 就行：\n${expectedLrcPath(track.path) ?? ''}',
          );
        }
        // 内嵌歌词经常是整段没有时间戳的文字：那种就只当文字显示。
        return lyrics.synced
            ? _syncedLyrics(context, lyrics)
            : _plainLyrics(context, lyrics);
      },
    );
  }

  /// 带时间轴：当前句高亮 + 自动滚到中间 + 点一句跳过去。
  Widget _syncedLyrics(BuildContext context, Lyrics lyrics) {
    _measure(lyrics);
    final active = _highlightLine(lyrics);
    // 换句了才滚：播放中每 500ms 会重建一次，不判断就会一直重启滚动动画。
    if (active != _activeIndex) {
      final wasUnknown = _activeIndex == null;
      _activeIndex = active;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && active != null) {
          // 第一次直接跳到位：从第一句一路滚下去看着很怪。
          _scrollToActive(active, animate: !wasUnknown);
        }
      });
    }

    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) => ListView.builder(
        controller: _controller,
        // 上下各留半屏：第一句与最后一句也能滚到中间。
        padding: EdgeInsets.symmetric(vertical: constraints.maxHeight / 2),
        itemCount: lyrics.lines.length,
        itemBuilder: (context, index) {
          final line = lyrics.lines[index];
          final isActive = index == active;
          final lineCount = lyricLineCount(line.text);
          return SizedBox(
            // 高度自己定死，滚动位置才算得准（见 `_heights` 的说明）。
            height: _heights[index],
            child: InkWell(
              // 点一句就跳过去。跳转是异步的，所以这里只**钉住**点的那一句（记下标），
              // 不猜位置：等播放快照回来时，只要位置还落在那句附近，它就还是当前句。
              // 只跳不钉的话，暂停时会亮在上一句——理由见 [kLyricPinPreRollMs]。
              onTap: line.timeMs > 0
                  ? () {
                      setState(() => _pinnedIndex = index);
                      widget.onSeek(line.timeMs);
                    }
                  : null,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: isActive && line.words.isNotEmpty
                      // 逐字歌词：唱到的字用主题色、没唱到的用弱化色。
                      ? _karaokeText(theme, line)
                      : Text(
                          line.text,
                          textAlign: TextAlign.center,
                          // 同一时间戳的两行歌词合成了一条，行数按它给，别被截掉。
                          maxLines: lineCount,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            // 行高压紧一点，两条双语歌词才装得进两格。
                            height: 1.25,
                            color: isActive
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurfaceVariant,
                            fontWeight: isActive
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 当前这一行按逐字时间轴渲染：唱到的字用主题色、没唱到的用弱化色。
  ///
  /// 整行的**字重保持不变**（只有颜色在动）：逐字改字重会让字宽跳动，一行字会跟着
  /// 左右抖。行尾那段（译文）本来就没有逐字信息，由 [karaokeRuns] 归到「未唱」里。
  Widget _karaokeText(ThemeData theme, LyricLine line) {
    final runs = karaokeRuns(line, widget.positionMs);
    final sung = theme.colorScheme.primary;
    return Text.rich(
      TextSpan(
        children: [
          for (final (text, isSung) in runs)
            // 未唱的不设颜色：跟着下面 style 里的弱化色走。
            TextSpan(text: text, style: isSung ? TextStyle(color: sung) : null),
        ],
      ),
      textAlign: TextAlign.center,
      maxLines: lyricLineCount(line.text),
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.titleMedium?.copyWith(
        height: 1.25,
        color: theme.colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  /// 算每条的高度与累计偏移；只在歌词换了一份（换歌 / 刚加载完）时重算。
  void _measure(Lyrics lyrics) {
    if (identical(_measured, lyrics)) return;
    _measured = lyrics;
    // 换了歌词（换歌 / 重新加载）：旧下标指的是另一份歌词里的句子，不能再钉着。
    _pinnedIndex = null;
    _heights = [
      for (final line in lyrics.lines)
        kLyricLineHeight * lyricLineCount(line.text),
    ];
    final offsets = <double>[];
    var total = 0.0;
    for (final height in _heights) {
      offsets.add(total);
      total += height;
    }
    _offsets = offsets;
  }

  /// 没有时间轴（内嵌歌词常见）：一段可滚动的文字，不做高亮。
  Widget _plainLyrics(BuildContext context, Lyrics lyrics) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final line in lyrics.lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                line.text,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 「没有歌词」「没有在播放」这类占位：一句主提示 + 可选的补充说明。
  Widget _hint(BuildContext context, String message, String? detail) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            if (detail != null) ...[
              const SizedBox(height: 8),
              Text(
                detail,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 该高亮第几句。
  ///
  /// 默认按位置算（见 [_activeLine]）；**用户点过某一句时那一句优先**——理由见
  /// [kLyricPinPreRollMs]。位置走出「点过那一句」这一段之后，钉子自动失效、回到
  /// 按位置算：要么播放已经进了下一句，要么用户又跳到别处去了。
  int? _highlightLine(Lyrics lyrics) {
    final pinned = _pinnedIndex;
    if (pinned != null && pinned < lyrics.lines.length) {
      final start = lyrics.lines[pinned].timeMs;
      final end = pinned + 1 < lyrics.lines.length
          ? lyrics.lines[pinned + 1].timeMs
          : null;
      // 还没到下一句（最后一句就没有下一句），也没退到这句之前太远。
      if (widget.positionMs >= start - kLyricPinPreRollMs &&
          (end == null || widget.positionMs < end)) {
        return pinned;
      }
    }
    return _activeLine(lyrics);
  }

  /// 当前该高亮第几句：最后一句 `timeMs <= 位置` 的。
  ///
  /// 与 Rust 的 `Lyrics::active_index` 同一条规则（那边是权威实现）；
  /// 这里每次重建都要算一遍，为了一句话过一趟 FFI 不值当，所以在 UI 侧再写一份。
  /// 位置在第一句之前时高亮第一句：歌词还没开始唱，但用户已经看到它了。
  int? _activeLine(Lyrics lyrics) {
    final lines = lyrics.lines;
    if (lines.isEmpty) return null;
    if (widget.positionMs < lines[0].timeMs) return 0;
    // 时间轴已排序，二分查找：长歌词里每 500ms 线性扫一遍是白费。
    var low = 0;
    var high = lines.length - 1;
    while (low < high) {
      final mid = (low + high + 1) ~/ 2;
      if (lines[mid].timeMs <= widget.positionMs) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low;
  }

  /// 把第 `index` 句滚到中间。
  ///
  /// 列表上下各留了半屏 padding，所以「中间」就是这条的
  /// `累计偏移 + 自己高度的一半`（多行条目更高，中心也更靠下）。
  void _scrollToActive(int index, {required bool animate}) {
    if (!_controller.hasClients) return;
    if (index < 0 || index >= _offsets.length) return;
    final target = (_offsets[index] + _heights[index] / 2).clamp(
      0.0,
      _controller.position.maxScrollExtent,
    );
    if ((_controller.offset - target).abs() < 1) return;
    if (animate) {
      _controller.animateTo(
        target,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    } else {
      _controller.jumpTo(target);
    }
  }
}
