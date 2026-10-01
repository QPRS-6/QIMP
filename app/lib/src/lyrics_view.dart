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
    final active = _activeLine(lyrics);
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
              // 点一句就跳过去。不做乐观高亮：跳转是异步的，位置由播放快照回来
              // 之后自然会亮起来，抢着改反而会闪。
              onTap: line.timeMs > 0 ? () => widget.onSeek(line.timeMs) : null,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
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
                      fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
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

  /// 算每条的高度与累计偏移；只在歌词换了一份（换歌 / 刚加载完）时重算。
  void _measure(Lyrics lyrics) {
    if (identical(_measured, lyrics)) return;
    _measured = lyrics;
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
