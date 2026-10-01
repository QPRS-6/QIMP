// Flutter 的 material 也导出了一个 `RepeatMode`（重复动画用）。
// 这里要用的是播放器的循环模式，所以把 Flutter 那个藏起来，避免歧义。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide RepeatMode;

import 'package:musicplayer/src/format.dart'
    show formatDuration, formatDurationLong;
import 'package:musicplayer/src/playback_buttons.dart';
import 'package:musicplayer/src/rust/api/library.dart';
import 'package:musicplayer/src/rust/api/player.dart';
import 'package:musicplayer/src/seek_slider.dart';
import 'package:musicplayer/src/sleep_timer.dart';
import 'package:musicplayer/src/system_volume.dart';

/// 封面加载器：默认走 Rust 的 `track_cover`，测试里换成确定性的桩。
typedef CoverLoader = Future<Uint8List?> Function(int trackId);

/// 音量读取器：默认读系统媒体音量，测试里换成确定性的桩。
typedef VolumeReader = Future<double?> Function();

/// 音量设置器：把音量设成某个比例（0..1），测试里换成记录调用的桩。
typedef VolumeSetter = Future<double?> Function(double ratio);

/// 封面上那层滑动手势的 key（测试用它定位手势区域）。
const Key coverSwipeKey = Key('player-cover-swipe');

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

/// 全屏播放界面。
///
/// 布局自上而下：封面 → 标题 / 艺术家 → 进度 → 上一曲·播放暂停·下一曲 →
/// 随机 / 定时播放 / 循环。左上角是「返回播放列表」，右上角暂时不放东西。
///
/// 封面上还能直接滑：右＝上一曲、左＝下一曲、上＝音量加、下＝音量减
/// （音量跟手线性：滑多少调多少）。
///
/// 它自己不持有播放状态：一切都来自曲库页传进来的快照通知器，
/// 所以这个页面上的按钮与底部播放条永远显示同一个状态。
class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.player,
    required this.trackById,
    required this.onToggle,
    required this.onNext,
    required this.onPrevious,
    required this.onSeek,
    required this.onCycleRepeat,
    required this.onToggleShuffle,
    required this.sleepTimer,
    this.loadCover = _loadCoverFromEngine,
    this.readVolume = _readSystemVolume,
    this.setVolume = _setSystemVolume,
  });

  /// 与曲库页共用同一个快照通知器（自动续播换歌时两边一起刷新）。
  final ValueListenable<PlayerSnapshot?> player;

  /// 按曲库 id 查曲目；查不到返回 null（列表被搜索过滤时用缓存兜底）。
  final Track? Function(int trackId) trackById;

  final VoidCallback onToggle;
  final VoidCallback onNext;
  final VoidCallback onPrevious;
  final ValueChanged<int> onSeek;
  final VoidCallback onCycleRepeat;
  final VoidCallback onToggleShuffle;

  /// 定时播放状态。由曲库页持有：退出本页之后倒计时还要继续走。
  final SleepTimer sleepTimer;

  final CoverLoader loadCover;

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

  /// 横向滑动：**右＝上一曲、左＝下一曲**（按用户要求的方向）。
  ///
  /// 注意速度的正负号：手指往右甩（内容向左走）速度为正，所以正号对应“回去”。
  void _onHorizontalSwipe(double velocity) {
    if (velocity >= _swipeVelocity) {
      _flash(
        const _GestureHint(icon: Icons.skip_previous, label: '上一曲'),
      );
      widget.onPrevious();
    } else if (velocity <= -_swipeVelocity) {
      _flash(
        const _GestureHint(icon: Icons.skip_next, label: '下一曲'),
      );
      widget.onNext();
    }
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
            // 右上角暂时不放东西。
            title: Text(
              (track?.album?.isNotEmpty ?? false) ? track!.album! : '正在播放',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
              child: Column(
                children: [
                  Expanded(
                    child: GestureDetector(
                      key: coverSwipeKey,
                      // 封面之外那片空白也接手势：用户“划封面”时手指常常落在
                      // 图片边上，只有图片本体可滑会显得不灵敏。
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragEnd: (details) =>
                          _onHorizontalSwipe(details.primaryVelocity ?? 0),
                      onVerticalDragStart: _onVerticalDragStart,
                      onVerticalDragUpdate: _onVerticalDragUpdate,
                      onVerticalDragEnd: _onVerticalDragEnd,
                      onVerticalDragCancel: _onVerticalDragCancel,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Center(
                            child: _CoverArt(
                              cover: track == null ? null : _coverOf(track.id),
                            ),
                          ),
                          // 提示层不能吃掉手势，所以套 IgnorePointer。
                          IgnorePointer(
                            child: AnimatedOpacity(
                              opacity: _hintVisible ? 1 : 0,
                              duration: const Duration(milliseconds: 150),
                              child: _hint == null
                                  ? const SizedBox.shrink()
                                  : _GestureHintBubble(hint: _hint!),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  _TrackTitles(track: track, errorText: snapshot?.error),
                  const SizedBox(height: 4),
                  if (snapshot != null) ...[
                    SeekSlider(
                      snapshot: snapshot,
                      totalMs: track?.durationMs ?? 0,
                      onSeek: widget.onSeek,
                    ),
                    _TimeRow(
                      positionMs: snapshot.positionMs,
                      totalMs: track?.durationMs ?? 0,
                    ),
                  ],
                  const SizedBox(height: 8),
                  _controls(snapshot),
                  const SizedBox(height: 8),
                  _bottomRow(snapshot),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 上一曲 / 播放暂停 / 下一曲。
  Widget _controls(PlayerSnapshot? snapshot) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          iconSize: 40,
          tooltip: '上一首',
          onPressed: widget.onPrevious,
          icon: const Icon(Icons.skip_previous),
        ),
        const SizedBox(width: 20),
        PlayPauseButton(
          state: snapshot?.state ?? PlayerState.stopped,
          onPressed: widget.onToggle,
          iconSize: 44,
        ),
        const SizedBox(width: 20),
        IconButton(
          iconSize: 40,
          tooltip: '下一首',
          onPressed: widget.onNext,
          icon: const Icon(Icons.skip_next),
        ),
      ],
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

  /// 选定时长；划掉弹窗＝什么都不做，「关闭定时」＝取消。
  Future<void> _pickSleepTimer(BuildContext context) async {
    final minutes = await showModalBottomSheet<int>(
      context: context,
      builder: (sheetContext) => SafeArea(
        // 用 ListView 而不是 Column：小屏 / 横屏时弹窗高度有限（默认只有屏幕的
        // 一半左右），7 个选项会直接溢出，列表版会自动变成可滚动。
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
              title: const Text('关闭定时'),
              enabled: widget.sleepTimer.isActive,
              onTap: () => Navigator.of(sheetContext).pop(_cancelChoice),
            ),
          ],
        ),
      ),
    );
    if (minutes == null) return;
    widget.sleepTimer.set(
      minutes == _cancelChoice ? null : Duration(minutes: minutes),
    );
  }

  /// 「关闭定时」的哨兵值：用它把「关掉定时」与「划掉弹窗」区分开。
  static const int _cancelChoice = 0;
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
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: scheme.onInverseSurface,
              ),
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
            child: Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true),
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
          track.title.isEmpty ? track.path.split('/').last : track.title,
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
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
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
