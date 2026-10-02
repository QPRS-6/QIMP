// Flutter 的 material 也导出了一个 `RepeatMode`（重复动画用）。
// 这里要用的是播放器的循环模式，所以把 Flutter 那个藏起来，避免歧义。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter/services.dart';

import 'package:musicplayer/src/format.dart'
    show formatDuration, formatDurationLong;
import 'package:musicplayer/src/lyrics_view.dart';
import 'package:musicplayer/src/playback_buttons.dart';
import 'package:musicplayer/src/queue_view.dart';
import 'package:musicplayer/src/rust/api/library.dart';
import 'package:musicplayer/src/rust/api/player.dart';
import 'package:musicplayer/src/seek_slider.dart';
import 'package:musicplayer/src/sleep_timer.dart';
import 'package:musicplayer/src/system_volume.dart';
import 'package:musicplayer/src/tablet_layout.dart';

/// 封面加载器：默认走 Rust 的 `track_cover`，测试里换成确定性的桩。
typedef CoverLoader = Future<Uint8List?> Function(int trackId);

/// 音量读取器：默认读系统媒体音量，测试里换成确定性的桩。
typedef VolumeReader = Future<double?> Function();

/// 音量设置器：把音量设成某个比例（0..1），测试里换成记录调用的桩。
typedef VolumeSetter = Future<double?> Function(double ratio);

/// 封面那张图上的滑动手势的 key（测试用它定位手势区域）。
///
/// 切歌与音量**只认这块区域**：手势区域就是那张图本身，不含它周围的空白。
/// 空白也接手势的话范围会显得太大（用户反馈）——上下滑想调音量、手指却落到了
/// 图外面，或者想轻轻划一下封面却换了歌，都特别容易发生。
const Key coverSwipeKey = Key('player-cover-swipe');

/// 上面那整块区域（封面 + 周围的空白）的 key。
///
/// 这一整块只接一件事：歌词页上「右滑回封面」。测试也用它定位「封面之外」的空白
/// ——从它的左上角往内 20 像素一定在那张图外面（图是居中的方块）。
const Key playerSwipeKey = Key('player-area-swipe');

/// 判定“这是一次滑动”的速度阈值（逻辑像素/秒）。
///
/// 太敏感会误触：用户只是想点一下进度条或不小心抹到封面就换歌；
/// 太小则要划很长才认。200 大致是“明显甩了一下”的手感。
const double _swipeVelocity = 200;

/// 音量跟手线性的换算基准：手指走满这么多逻辑像素，音量正好走完 0→100%。
///
/// 挑 320 是因为一次舒服的滑动就能走过大半段，又不至于轻轻一碰跳一大截
/// （换算下来每 32 像素 ≈ 10%）。
const double _volumeDragFullRange = 320;

/// 纵向位移小于这个距离就不算「要调音量」。
///
/// 点一下、横向滑动时手指总会带一点纵向抖动；不留这块缓冲区，
/// 随手碰一下就会把音量改掉。
const double _volumeDragDeadZone = 8;

/// 默认音量来源：系统媒体音量。
Future<double?> _readSystemVolume() => SystemVolume.current();

/// 默认音量去向：按比例设成系统媒体音量。
Future<double?> _setSystemVolume(double ratio) => SystemVolume.setRatio(ratio);

/// 默认封面来源：Rust 侧按「内嵌图 → 同目录的 cover.jpg / folder.jpg 等」找。
Future<Uint8List?> _loadCoverFromEngine(int trackId) async {
  final cover = await trackCover(trackId: trackId);
  return cover?.data;
}

/// 默认歌词来源：Rust 侧按「同目录同名的 .lrc → 文件内嵌歌词」找。
Future<Lyrics?> _loadLyricsFromEngine(int trackId) =>
    trackLyrics(trackId: trackId);

/// 全屏播放界面。
///
/// 上面那块在手机上是**两页**：封面页与歌词页（见 [LyricsView]），进歌词页走封面
/// **左上角**那颗「歌词」按钮，回封面走歌词页**左上角**那颗专辑图标（用户明确要求没有
/// 滑动手势，见下面的手势表）。布局自上而下：两块页面之一 →
/// 标题 / 艺术家 → 进度 → 上一曲·播放暂停·下一曲 → 随机 / 定时播放 / 循环。
/// 左上角是「返回播放列表」，右上角暂时不放东西。
///
/// 手势（与封面页上的提示气泡一致）：
/// - **封面那张图上**：右滑＝上一曲、左滑＝下一曲、上滑＝音量加、下滑＝音量减（跟手线性）；
/// - **封面之外的空白**：什么手势都不接（用户反馈过范围太大）；
/// - **歌词页**：右滑＝回封面页；左滑什么都不做（用户要求：歌词页的滑动不要切歌）；
///   上下滑留给歌词自己滚。
///
/// **翻页没有滑动手势**：用户明确要求关掉「滑动进歌词」——它和「左滑下一曲」
/// 太容易撞（起点偏一点、甩快一点，意思就变了）。翻页走左上角那颗按钮。
///
/// 它自己不持有播放状态：一切都来自曲库页传进来的快照通知器，
/// 所以这个页面上的按钮与底部播放条永远显示同一个状态。
///
/// **窗口够宽时改成左右分栏**（见 [useTabletLayout] 与 [isLandscape]），一共三套版式：
///
/// | 窗口 | 版式 |
/// | --- | --- |
/// | 平板 | 左栏＝封面 + 控制区，右栏＝整块歌词。地方够宽，歌词就该一直看得见，翻页按钮都不出现 |
/// | 手机横屏 | 左栏＝封面（**左上角**那颗「歌词」按钮把它换成歌词），右栏＝控制区。看歌词时右边照样能暂停 / 切歌；换回封面点左栏**左上角**那颗专辑图标 |
/// | 手机竖屏 | 老样子：封面页与歌词页二选一，进歌词页走封面**左上角**那颗按钮，回封面走歌词页**左上角**那颗 |
///
/// 手势规则一字不改：切歌与音量仍然只认封面那张图。
class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.player,
    required this.queue,
    required this.trackById,
    required this.onToggle,
    required this.onNext,
    required this.onPrevious,
    required this.onSeek,
    required this.onJump,
    required this.onCycleRepeat,
    required this.onToggleShuffle,
    required this.sleepTimer,
    this.loadCover = _loadCoverFromEngine,
    this.loadLyrics = _loadLyricsFromEngine,
    this.readVolume = _readSystemVolume,
    this.setVolume = _setSystemVolume,
  });

  /// 与曲库页共用同一个快照通知器（自动续播换歌时两边一起刷新）。
  final ValueListenable<PlayerSnapshot?> player;

  /// 当前播放队列（曲库页持有的那份镜像）。底部弹出的半屏列表读它。
  final ValueListenable<List<QueueEntry>> queue;

  /// 按曲库 id 查曲目；查不到返回 null（列表被搜索过滤时用缓存兜底）。
  final Track? Function(int trackId) trackById;

  final VoidCallback onToggle;
  final VoidCallback onNext;
  final VoidCallback onPrevious;
  final ValueChanged<int> onSeek;

  /// 跳到队列里的第 `index` 首（从底部弹出的列表里点一首）。
  final ValueChanged<int> onJump;

  final VoidCallback onCycleRepeat;
  final VoidCallback onToggleShuffle;

  /// 定时播放状态。由曲库页持有：退出本页之后倒计时还要继续走。
  final SleepTimer sleepTimer;

  final CoverLoader loadCover;

  /// 取歌词（同目录同名的 `.lrc` 优先，其次内嵌歌词）；没有返回 null。
  final LyricsLoader loadLyrics;

  /// 读当前系统媒体音量（0..1）；读不到返回 null。
  final VolumeReader readVolume;

  /// 把系统媒体音量设成某个比例（0..1），返回平台落定后的比例。
  final VolumeSetter setVolume;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  /// 封面按曲目 id 缓存：本页每 500ms 会被快照刷一次，
  /// 不缓存就会一遍遍重新读文件、重新解码整张图。
  final Map<int, Future<Uint8List?>> _covers = {};

  /// 歌词同样按曲目 id 缓存（每次重建都重新读一遍 `.lrc` 是没必要的）。
  final Map<int, Future<Lyrics?>> _lyrics = {};

  /// 上面那一块现在是歌词页还是封面页。
  bool _showLyrics = false;

  /// 滑动后封面中央那个小提示（当前内容 / 是否可见）。
  _GestureHint? _hint;
  bool _hintVisible = false;
  Timer? _hintTimer;

  /// 本次纵向拖动累计的位移（向上为正，逻辑像素）。
  double _volumeDragDy = 0;

  /// 本次纵向拖动的起点音量（比例）；还没读回来时是 null。
  double? _volumeDragStart;

  /// 读取起点音量的过程：松手时若还没回来，就等它一下再算。
  Future<double?> _volumeDragRead = Future<double?>.value();

  /// 拖动序号：每次按下自增，用来丢掉上一把迟到的异步结果。
  int _volumeDragToken = 0;

  Future<Uint8List?> _coverOf(int trackId) =>
      _covers[trackId] ??= widget.loadCover(trackId);

  /// 取这首歌的歌词（缓存同一个 Future：本页每 500ms 重建一次）。
  Future<Lyrics?>? _lyricsOf(int? trackId) {
    if (trackId == null || trackId <= 0) return null;
    return _lyrics[trackId] ??= widget.loadLyrics(trackId);
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    super.dispose();
  }

  /// 在封面中央闪一下提示，约一秒后自动淡出。
  void _flash(_GestureHint hint) {
    _hintTimer?.cancel();
    setState(() {
      _hint = hint;
      _hintVisible = true;
    });
    _hintTimer = Timer(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      setState(() => _hintVisible = false);
    });
  }

  /// 让提示立刻淡出（内容留着，只是透明度归零）。
  void _hideHint() {
    _hintTimer?.cancel();
    if (!_hintVisible) return;
    setState(() => _hintVisible = false);
  }

  /// 横向滑动（方向按页不同，见类注释）。
  ///
  /// 注意速度的正负号：手指往右甩（内容向左走）速度为正，所以正号对应“回去”。
  void _onHorizontalSwipe(double velocity) {
    final backward = velocity >= _swipeVelocity;
    final forward = velocity <= -_swipeVelocity;
    if (!backward && !forward) return;

    if (_showLyrics) {
      // 歌词页：右滑回封面。**左滑不切歌**——用户明确要求歌词页的滑动不要切歌。
      if (backward) _showCover();
      return;
    }

    // 封面页：右滑上一曲、左滑下一曲（从第一天起就是这样）。
    // 进歌词页**只走左上角那个按钮**：用户要求关掉滑动翻页的手势——
    // 它和「左滑下一曲」太容易撞（滑快一点、起点偏一点就换了意思）。
    if (backward) {
      _flash(const _GestureHint(icon: Icons.skip_previous, label: '上一曲'));
      widget.onPrevious();
    } else {
      _flash(const _GestureHint(icon: Icons.skip_next, label: '下一曲'));
      widget.onNext();
    }
  }

  /// 翻到歌词页。
  void _showLyricsPage() {
    // 封面上那个「上一曲 / 下一曲」提示留在封面页上，翻页时先收掉。
    _hideHint();
    if (_showLyrics) return;
    setState(() => _showLyrics = true);
  }

  /// 翻回封面页。
  void _showCover() {
    _hideHint();
    if (!_showLyrics) return;
    setState(() => _showLyrics = false);
  }

  /// 纵向拖动：上＝音量加、下＝音量减，**跟手线性**。
  ///
  /// 划过的距离按 [_volumeDragFullRange] 换算成音量——滑多少调多少，
  /// 而不是「划一下就固定加一格」。拖动过程中只刷新封面上的百分比，
  /// 松手才写进系统音量：否则每一帧都要过一次平台通道，系统的音量条也会闪个不停。
  void _onVerticalDragStart(DragStartDetails details) {
    final token = ++_volumeDragToken;
    _volumeDragDy = 0;
    _volumeDragStart = null;
    // 以「按下那一刻的音量」为基准：用户用侧键改过之后也不会算歪。
    final read = _volumeDragRead = widget.readVolume();
    unawaited(
      read.then((ratio) {
        if (!mounted || token != _volumeDragToken) return;
        _volumeDragStart = ratio;
      }),
    );
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    _volumeDragDy -= details.delta.dy; // 手指往上走为正
    final start = _volumeDragStart;
    if (start == null || _volumeDragDy.abs() < _volumeDragDeadZone) return;
    final ratio = _volumeRatioAt(start, _volumeDragDy);
    _flash(_volumeHint(ratio, goingUp: _volumeDragDy > 0));
  }

  Future<void> _onVerticalDragEnd(DragEndDetails details) async {
    final dy = _volumeDragDy;
    _volumeDragDy = 0;
    final token = _volumeDragToken;
    // 起点音量通常早就回来了；平台侧慢的话就在这儿等一下。
    final start = await _volumeDragRead;
    if (!mounted || token != _volumeDragToken) return;
    // 读不到起点、或者只是碰了一下：当没这回事，别把音量设成 0 之类的怪值。
    if (start == null || dy.abs() < _volumeDragDeadZone) return;

    final applied = await widget.setVolume(_volumeRatioAt(start, dy));
    if (!mounted || token != _volumeDragToken) return;
    if (applied == null) {
      // 没设成功：把拖动时那个预测值收起来，别让用户以为它已经生效。
      _hideHint();
      return;
    }
    _flash(_volumeHint(applied, goingUp: dy > 0));
  }

  void _onVerticalDragCancel() {
    _volumeDragToken += 1;
    _volumeDragDy = 0;
    _volumeDragStart = null;
  }

  /// 从起点滑了 [dy] 像素（向上为正）之后的音量比例，夹在 0..1。
  double _volumeRatioAt(double start, double dy) =>
      (start + dy / _volumeDragFullRange).clamp(0.0, 1.0);

  /// 音量提示：往哪边滑就用哪个图标。
  _GestureHint _volumeHint(double ratio, {required bool goingUp}) =>
      _GestureHint(
        icon: goingUp ? Icons.volume_up : Icons.volume_down,
        label: '音量 ${(ratio * 100).round()}%',
      );

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PlayerSnapshot?>(
      valueListenable: widget.player,
      builder: (context, snapshot, _) {
        final track = snapshot == null
            ? null
            : widget.trackById(snapshot.trackId);
        return Scaffold(
          appBar: AppBar(
            leading: IconButton(
              tooltip: '返回播放列表',
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back),
            ),
            // 顶栏颜色**固定**，两条原因：
            // 1. M3 的 AppBar 会在「有内容滚到它下面」时自动加一层染色（surface tint），
            //    于是同一页在封面页发白、切到歌词页（那边是个滚动列表）明显变深——
            //    用户一眼就看出来了，会以为状态变了；
            // 2. 那就把深的那一份定下来：颜色取「滚动到下面」时那层，
            //    再关掉自动染色，两页就是同一条标题栏了。
            backgroundColor: _appBarColor(Theme.of(context)),
            surfaceTintColor: Colors.transparent,
            scrolledUnderElevation: 0,
            // 曲名（不是专辑名）：专辑是「这张唱片」，不是「在放的这首」。
            // 顶栏在歌词页是唯一的曲名来源，所以这里必须留着它。
            title: Text(
              _displayTitle(track) ?? '正在播放',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
              child: _body(track, snapshot, size: MediaQuery.sizeOf(context)),
            ),
          ),
        );
      },
    );
  }

  /// 按窗口挑版式（三套，见类注释）。
  ///
  /// 三套共用同一份控制区（[_transport]）与同一个 [LyricsView]，
  /// 所以按钮顺序、间距、歌词手感不会各长一样。
  Widget _body(Track? track, PlayerSnapshot? snapshot, {required Size size}) {
    // 平板：左边一栏控制、右边一栏歌词，横竖都是这一套——地方够宽，
    // 歌词就该一直看得见。
    if (useTabletLayout(size)) {
      return _wideBody(track, snapshot);
    }
    // 手机横屏：左边封面、右边控制。竖向只剩三百来点，竖着排塞不下。
    if (isLandscape(size)) {
      return _landscapeBody(track, snapshot);
    }
    // 手机竖屏：老样子，封面页 / 歌词页二选一。
    return _narrowBody(track, snapshot);
  }

  /// 手机横屏那一页：**左边封面、右边控制区**。
  ///
  /// 左边那一栏会在封面与歌词之间切换（就是封面上那颗「歌词」按钮，位置在封面的
  /// 左上角），**右边始终是控制区**——看歌词的时候也能暂停 / 切歌 / 拖进度，
  /// 这也是分栏的意义所在（竖屏那套里翻到歌词页就只剩歌词了）。
  Widget _landscapeBody(Track? track, PlayerSnapshot? snapshot) {
    return Row(
      children: [
        Expanded(
          flex: 5,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (_showLyrics)
                _lyricsPane(track, snapshot, onBack: _showCover)
              else
                _coverPane(track, withLyricsButton: true),
              _hintLayer(),
            ],
          ),
        ),
        // 一像素的竖线：两栏并排时，光靠间距看不出「这是两块」。
        const VerticalDivider(width: 1, thickness: 1),
        Expanded(
          flex: 4,
          // 能滚：小屏横过来之后这一栏很矮，内容比它高时不该顶出边界。
          // 装得下就居中摆着，不然一排按钮贴着上面、下面空一大块。
          child: Center(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: _transport(track, snapshot),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 手机上的那一页：上面是封面页与歌词页（二选一），下面是控制区。
  Widget _narrowBody(Track? track, PlayerSnapshot? snapshot) {
    return Column(
      children: [
        Expanded(
          child: GestureDetector(
            // 这一整块（含封面之外的空白）只接一件事：歌词页上右滑回封面。
            // 封面页的切歌 / 音量手势只认下面那张图，所以这里在封面页
            // 干脆不挂横向回调——空白处就什么都不会发生。
            key: playerSwipeKey,
            behavior: HitTestBehavior.opaque,
            onHorizontalDragEnd: !_showLyrics
                ? null
                : (details) => _onHorizontalSwipe(details.primaryVelocity ?? 0),
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (_showLyrics)
                  _lyricsPane(track, snapshot, onBack: _showCover)
                else
                  _coverPane(track, withLyricsButton: true),
                _hintLayer(),
              ],
            ),
          ),
        ),
        // 控制区（标题 / 进度 / 按钮）：手机竖着一路排下来。
        ..._transport(track, snapshot),
      ],
    );
  }

  /// 平板上的那一页：**左右分栏**。
  ///
  /// 左边一栏还是原来那一套播放控制（封面 / 标题 / 进度 / 按钮），右边一栏整块放歌词：
  /// 横向的地方够，歌词就该一直看得见，不用再「翻」出来。
  /// 左边给 5 份、右边 4 份：封面是方的，栏太窄会缩得比按钮还小。
  Widget _wideBody(Track? track, PlayerSnapshot? snapshot) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 5,
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    _coverPane(track, withLyricsButton: false),
                    _hintLayer(),
                  ],
                ),
              ),
              // 与手机上共用同一份控制区：两边的按钮顺序、间距、行为不会各长一样。
              ..._transport(track, snapshot),
            ],
          ),
        ),
        // 一像素的竖线：两栏并排时，光靠间距看不出「这是两块」。
        const VerticalDivider(width: 1, thickness: 1),
        Expanded(
          flex: 4,
          // 平板上没有「封面页 / 歌词页」之分，所以这一栏不需要「回封面」。
          child: _lyricsPane(track, snapshot, onBack: null),
        ),
      ],
    );
  }

  /// 封面那一块：图 + 切歌 / 音量手势；右上角那个「歌词」按钮按需带上
  /// （平板上歌词本来就在右边，翻页按钮没有意义）。
  Widget _coverPane(Track? track, {required bool withLyricsButton}) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Center(
          // 手势区域＝封面那张图：切歌、调音量都在它身上。
          // 内层的手势识别器会先拿到事件，所以它和外面那层
          // 「整块区域」不会互相打架。
          child: GestureDetector(
            key: coverSwipeKey,
            behavior: HitTestBehavior.opaque,
            onHorizontalDragEnd: (details) =>
                _onHorizontalSwipe(details.primaryVelocity ?? 0),
            onVerticalDragStart: _onVerticalDragStart,
            onVerticalDragUpdate: _onVerticalDragUpdate,
            onVerticalDragEnd: _onVerticalDragEnd,
            onVerticalDragCancel: _onVerticalDragCancel,
            child: _CoverArt(
              cover: track == null ? null : _coverOf(track.id),
            ),
          ),
        ),
        if (withLyricsButton)
          // 封面**左上角**：切到歌词。翻页**不再有滑动手势**——
          // 用户要求关掉它（和「左滑下一曲」太容易撞），
          // 于是这个按钮就是唯一的入口，必须看得见、点得着。
          // 放左上角（不是右上角）：横屏/平板上封面在左边，右上角已经贴着两栏的
          // 交界了，左上角才是这颗按钮自己的角落。
          Align(
            alignment: Alignment.topLeft,
            child: IconButton(
              tooltip: '歌词',
              onPressed: _showLyricsPage,
              icon: const Icon(Icons.lyrics_outlined),
            ),
          ),
      ],
    );
  }

  /// 歌词那一栏。[onBack] 为 null 时不带「回封面」（平板上它常驻，没有可回的）。
  Widget _lyricsPane(
    Track? track,
    PlayerSnapshot? snapshot, {
    VoidCallback? onBack,
  }) {
    return LyricsView(
      track: track,
      lyrics: _lyricsOf(track?.id),
      positionMs: snapshot?.positionMs ?? 0,
      onSeek: widget.onSeek,
      onBack: onBack,
    );
  }

  /// 封面正中那个手势提示（切歌 / 音量）。不能吃掉手势，所以套 IgnorePointer。
  Widget _hintLayer() {
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: _hintVisible ? 1 : 0,
        duration: const Duration(milliseconds: 150),
        child: _hint == null
            ? const SizedBox.shrink()
            : _GestureHintBubble(hint: _hint!),
      ),
    );
  }

  /// 控制区：标题 / 艺术家 →（进度 → 两端时间）→ 上一曲·播放·下一曲·播放列表
  /// → 随机 · 定时播放 · 循环。
  ///
  /// 手机与平板共用这一份（平板把它放在左栏底部），于是两边的按钮顺序、
  /// 间距、手感永远一致。
  List<Widget> _transport(Track? track, PlayerSnapshot? snapshot) {
    return [
      const SizedBox(height: 20),
      _TrackTitles(track: track, errorText: snapshot?.error),
      const SizedBox(height: 4),
      if (snapshot != null) ...[
        SeekSlider(
          snapshot: snapshot,
          totalMs: trackTotalMs(
            fromLibrary: track?.durationMs ?? 0,
            fromEngine: snapshot.durationMs,
          ),
          onSeek: widget.onSeek,
        ),
        _TimeRow(
          positionMs: snapshot.positionMs,
          // 同上：曲库没记时长时用解码器算出来的那份。
          totalMs: trackTotalMs(
            fromLibrary: track?.durationMs ?? 0,
            fromEngine: snapshot.durationMs,
          ),
        ),
      ],
      const SizedBox(height: 8),
      _controls(snapshot),
      const SizedBox(height: 8),
      _bottomRow(snapshot),
    ];
  }

  /// 上一曲 / 播放暂停 / 下一曲 / 播放列表。
  ///
  /// 四个按钮平分整行（`spaceEvenly`）：多加一个按钮之后，若还按「居中 + 固定
  /// 间距」排，播放键会被挤得明显偏左。
  Widget _controls(PlayerSnapshot? snapshot) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(
          iconSize: 40,
          tooltip: '上一首',
          onPressed: widget.onPrevious,
          icon: const Icon(Icons.skip_previous),
        ),
        PlayPauseButton(
          state: snapshot?.state ?? PlayerState.stopped,
          onPressed: widget.onToggle,
          iconSize: 44,
        ),
        IconButton(
          iconSize: 40,
          tooltip: '下一首',
          onPressed: widget.onNext,
          icon: const Icon(Icons.skip_next),
        ),
        // 按用户要求放在「下一曲」右边：点一下从底部弹出半屏播放列表。
        IconButton(
          iconSize: 40,
          tooltip: '播放列表',
          onPressed: _showQueue,
          icon: const Icon(Icons.queue_music),
        ),
      ],
    );
  }

  /// 从底部弹出半屏播放队列。
  ///
  /// 列表本体直接复用「队列」视图（[QueueView]），所以它、抽屉里的「队列」、
  /// 以及真正在放的引擎三者永远说的是同一件事。点一首就跳过去并关掉弹窗
  /// ——播放界面上的标题与进度会立刻变成新那一首，比留在弹窗里看着有用。
  Future<void> _showQueue() {
    return showModalBottomSheet<void>(
      context: context,
      // 自己控高：默认那一档只有屏幕的 9/16，而且高度会随内容伸缩。
      isScrollControlled: true,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height / 2,
        // 列表滚到底时别被手势条压住。
        child: SafeArea(
          top: false,
          child: QueueView(
            queue: widget.queue,
            player: widget.player,
            trackById: widget.trackById,
            onJump: (index) {
              Navigator.of(sheetContext).pop();
              widget.onJump(index);
            },
          ),
        ),
      ),
    );
  }

  /// 随机 / 定时播放 / 循环。
  Widget _bottomRow(PlayerSnapshot? snapshot) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        ShuffleButton(
          on: snapshot?.shuffle ?? false,
          onPressed: widget.onToggleShuffle,
        ),
        // 定时播放：剩余时间直接写在按钮上，一眼能看出还剩多久。
        ListenableBuilder(
          listenable: widget.sleepTimer,
          builder: (context, _) => _sleepTimerButton(context),
        ),
        RepeatButton(
          mode: snapshot?.repeat ?? RepeatMode.off,
          onPressed: widget.onCycleRepeat,
        ),
      ],
    );
  }

  /// 定时播放按钮：没在定时就是描边秒表，在定时就把剩余时间写在上面。
  Widget _sleepTimerButton(BuildContext context) {
    final theme = Theme.of(context);
    final remaining = widget.sleepTimer.remaining;
    if (remaining == null) {
      return IconButton(
        tooltip: sleepTimerTooltip(null),
        onPressed: () => _pickSleepTimer(context),
        icon: const Icon(Icons.timer_outlined),
      );
    }
    return IconButton(
      tooltip: sleepTimerTooltip(remaining),
      onPressed: () => _pickSleepTimer(context),
      // 剩余时间直接写在按钮上。字号比旁边的图标小一档、行高压到 1：
      // 否则这串字比图标“胖一圈”，还会看着偏下（IconButton 是按图标方格居中的）。
      icon: Text(
        formatDuration(remaining.inMilliseconds),
        textAlign: TextAlign.center,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.primary,
          height: 1,
        ),
      ),
    );
  }

  /// 选定时长；划掉弹窗＝什么都不做，「关闭定时」＝取消，「自定义…」＝自己输入分钟数。
  Future<void> _pickSleepTimer(BuildContext context) async {
    final minutes = await showModalBottomSheet<int>(
      context: context,
      builder: (sheetContext) => SafeArea(
        // 用 ListView 而不是 Column：小屏 / 横屏时弹窗高度有限（默认只有屏幕的
        // 一半左右），几个选项加上自定义会直接溢出，列表版会自动变成可滚动。
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              dense: true,
              title: Text(
                '定时播放',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            for (final preset in SleepTimer.presets)
              ListTile(
                title: Text('$preset 分钟'),
                onTap: () => Navigator.of(sheetContext).pop(preset),
              ),
            ListTile(
              title: const Text('自定义…'),
              onTap: () => Navigator.of(sheetContext).pop(_customChoice),
            ),
            ListTile(
              title: const Text('关闭定时'),
              enabled: widget.sleepTimer.isActive,
              onTap: () => Navigator.of(sheetContext).pop(_cancelChoice),
            ),
          ],
        ),
      ),
    );
    if (minutes == null) return;
    if (minutes == _customChoice) {
      // 弹窗关掉之后再用一次 context：先确认自己还在树上。
      if (!context.mounted) return;
      await _pickCustomMinutes(context);
      return;
    }
    widget.sleepTimer.set(
      minutes == _cancelChoice ? null : Duration(minutes: minutes),
    );
  }

  /// 「自定义…」：让用户自己敲分钟数。
  ///
  /// 用弹窗而不是把输入框塞进底部菜单：键盘弹起来时底部菜单会被顶走，
  /// 输入框跟着一起跑，很难点。
  Future<void> _pickCustomMinutes(BuildContext context) async {
    final minutes = await showDialog<int>(
      context: context,
      builder: (_) => const _CustomMinutesDialog(),
    );
    if (minutes == null) return;
    widget.sleepTimer.set(Duration(minutes: minutes));
  }

  /// 「关闭定时」的哨兵值：用它把「关掉定时」与「划掉弹窗」区分开。
  static const int _cancelChoice = 0;

  /// 「自定义…」的哨兵值（分钟数为 0 没有意义，正好拿来当标记）。
  static const int _customChoice = -1;
}

/// 自定义定时时长的输入框。
///
/// 单独做成一个小组件（而不是一堆局部变量 + `StatefulBuilder`）：
/// 这是播放界面里唯一一处表单式输入，写成一个类更好读，也更好测。
class _CustomMinutesDialog extends StatefulWidget {
  const _CustomMinutesDialog();

  /// 允许的分钟数范围：至少 1 分钟，最多一天。
  ///
  /// 0 等于「立刻暂停」，比一天更长的定时没有意义——两者都只会让人以为没生效。
  static const int minMinutes = 1;
  static const int maxMinutes = 24 * 60;

  @override
  State<_CustomMinutesDialog> createState() => _CustomMinutesDialogState();
}

class _CustomMinutesDialogState extends State<_CustomMinutesDialog> {
  final TextEditingController _controller = TextEditingController();

  /// 当前输入对应的合法分钟数；`null` 表示还不能确认。
  int? _minutes;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String raw) {
    final value = int.tryParse(raw.trim());
    final valid =
        value != null &&
        value >= _CustomMinutesDialog.minMinutes &&
        value <= _CustomMinutesDialog.maxMinutes;
    setState(() => _minutes = valid ? value : null);
  }

  void _submit() {
    final minutes = _minutes;
    if (minutes == null) return;
    Navigator.of(context).pop(minutes);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('自定义定时'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        // 只让输入数字：别的字符进来只会让「开始」一直是灰的，不如直接拦掉。
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: const InputDecoration(
          labelText: '分钟',
          helperText: '1 ~ 1440，到点后自动暂停',
        ),
        onChanged: _onChanged,
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          // 输入不合法（空、0、超过一天）时按钮是灰的：免得点了没反应。
          onPressed: _minutes == null ? null : _submit,
          child: const Text('开始'),
        ),
      ],
    );
  }
}

/// 定时播放按钮的提示；`remaining` 为 null 表示当前没有在定时。
String sleepTimerTooltip(Duration? remaining) => remaining == null
    ? '定时播放：关闭（点击设置）'
    : '定时播放：剩余 ${formatDuration(remaining.inMilliseconds)}（点击修改）';

/// 滑动之后封面中央那个小提示的内容。
class _GestureHint {
  const _GestureHint({required this.icon, required this.label});

  final IconData icon;
  final String label;
}

/// 提示气泡：半透明底 + 图标 + 文案，压在封面正中。
class _GestureHintBubble extends StatelessWidget {
  const _GestureHintBubble({required this.hint});

  final _GestureHint hint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        // 用 M3 的“反色”配色而不是半透明黑：深色/浅色主题下都清楚，
        // 也不需要自己算透明度。
        color: scheme.inverseSurface,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(hint.icon, size: 20, color: scheme.onInverseSurface),
            const SizedBox(width: 8),
            Text(
              hint.label,
              style: Theme.of(context).textTheme.labelLarge
                  ?.copyWith(color: scheme.onInverseSurface),
            ),
          ],
        ),
      ),
    );
  }
}

/// 封面：有图就铺满一个圆角方块，没有就退化成占位图。
class _CoverArt extends StatelessWidget {
  const _CoverArt({required this.cover});

  /// 封面字节；`null` 表示没有封面（或还没加载出来）。
  final Future<Uint8List?>? cover;

  @override
  Widget build(BuildContext context) {
    if (cover == null) {
      return const _CoverPlaceholder();
    }
    return FutureBuilder<Uint8List?>(
      future: cover,
      builder: (context, data) {
        final bytes = data.data;
        if (bytes == null || bytes.isEmpty) {
          return const _CoverPlaceholder();
        }
        // gaplessPlayback：换曲时别闪一下白，直接把新图换上去。
        return ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: AspectRatio(
            aspectRatio: 1,
            child: Image.memory(
              bytes,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            ),
          ),
        );
      },
    );
  }
}

/// 没有封面时的占位图：一个圆角方块 + 音符，和曲目列表里的图标一致。
class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: AspectRatio(
        aspectRatio: 1,
        child: ColoredBox(
          color: scheme.surfaceContainerHighest,
          child: Icon(
            Icons.music_note,
            size: 96,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// 顶栏那一层「滚动到内容下面」的高度补偿，Flutter 的 M3 默认就是 3。
const double _appBarScrolledUnderElevation = 3;

/// 播放界面顶栏的固定底色。
///
/// 取的是 M3 里「有内容滚到 AppBar 下面」时那层颜色（就是歌词页上那个更深的样子）：
/// 不这么做的话，同一个顶栏在封面页是浅色、切到歌词页（那边是滚动列表）就自己变深，
/// 看起来像两个不同的状态。
Color _appBarColor(ThemeData theme) => ElevationOverlay.applySurfaceTint(
  theme.colorScheme.surface,
  theme.colorScheme.surfaceTint,
  _appBarScrolledUnderElevation,
);

/// 曲目在界面上显示的名字：标签里没写就退回文件名。
///
/// 顶栏与下面那行大标题共用它——不共用的话会出现
/// 「顶栏一个名字、正文另一个名字（或者干脆空的）」这种不一致。
String? _displayTitle(Track? track) {
  if (track == null) return null;
  return track.title.isEmpty ? track.path.split('/').last : track.title;
}

/// 标题 / 艺术家 · 专辑；播放失败时把原因摆在最显眼的位置。
class _TrackTitles extends StatelessWidget {
  const _TrackTitles({required this.track, this.errorText});

  final Track? track;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final errorText = this.errorText;
    if (errorText != null) {
      return Text(
        '播不了：$errorText',
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.error,
        ),
      );
    }

    final track = this.track;
    if (track == null) {
      return Text('没有在播放', style: theme.textTheme.titleMedium);
    }
    final subtitle = <String>[
      if (track.artist?.isNotEmpty ?? false) track.artist!,
      if (track.album?.isNotEmpty ?? false) track.album!,
    ].join(' · ');
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _displayTitle(track)!,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleLarge,
        ),
        if (subtitle.isNotEmpty)
          Text(
            subtitle,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

/// 进度条两端的时间：已播 / 总时长。
///
/// 用 [formatDurationLong] 而不是 [formatDuration]：后者把 0 当成「未知」显示
/// `--:--`，而这里开头的 0 就是 0（超过一小时的曲目也能正确显示 `1:05:30`）。
class _TimeRow extends StatelessWidget {
  const _TimeRow({required this.positionMs, required this.totalMs});

  final int positionMs;
  final int totalMs;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelMedium
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(formatDurationLong(positionMs), style: style),
          Text(formatDurationLong(totalMs), style: style),
        ],
      ),
    );
  }
}
