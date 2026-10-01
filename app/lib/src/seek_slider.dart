// Flutter 的 material 也导出了一个 `RepeatMode`（重复动画用）。
// 这里要用的是播放器的循环模式，所以把 Flutter 那个藏起来，避免歧义。
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:musicplayer/src/rust/api/player.dart';

/// 「这首歌到底多长」：曲库记的那份优先，它记不出来时用解码器解出来的那份。
///
/// 为什么会有两份：曲库那份来自标签/容器解析（lofty），通常更权威，列表里显示的就是它；
/// 但**有些文件标签里就是没有时长，却能正常解码播放**——真机上遇到过一个
/// 「从 mp4 里扒出来、文件名叫 `.mp3`」的音频：标签能读出标题与艺术家，时长是 0。
/// 解码器那边是从容器里算出来的（336 秒），正好补上这个洞。
/// 两份都没有时返回 0，表示“不知道”（UI 显示 `--:--`，进度条也不给拖）。
int trackTotalMs({required int fromLibrary, required int fromEngine}) =>
    fromLibrary > 0 ? fromLibrary : fromEngine;

/// 进度条：把「拖动跟手 / 跳转后锁住目标位置」这段时序收在一处。
///
/// 为什么需要它：`seek` 是异步的（口令丢给播放线程），紧接着读到的那次快照
/// 仍然是**跳转前**的位置。若松手后立刻跟随轮询值，滑块就会先弹回旧位置、
/// 等下一轮（最多 500ms）再跳到新位置——看起来就是「抽一下」。
///
/// 底部播放条与全屏播放界面共用它：两处的进度条手感必须一致，
/// 而这段时序在真机上很难复现（要抢在播放线程消化口令之前），只能靠单测钉住
/// （见 `test/now_playing_bar_test.dart`）。
class SeekSlider extends StatefulWidget {
  const SeekSlider({
    super.key,
    required this.snapshot,
    required this.totalMs,
    required this.onSeek,
  });

  /// 播放状态快照（当前位置 / 当前曲目都在里面）。
  final PlayerSnapshot snapshot;

  /// 曲库里记的总时长（毫秒）；`0` 表示曲库不知道，此时会用
  /// `snapshot.durationMs`（解码器从容器里算出来的那份）兜底。
  final int totalMs;

  /// 松手时把目标位置交出去（毫秒）。
  final ValueChanged<int> onSeek;

  @override
  State<SeekSlider> createState() => _SeekSliderState();
}

class _SeekSliderState extends State<SeekSlider> {
  /// 拖动中的位置（毫秒）；非 null 时不理会外部轮询值。
  double? _dragging;

  /// 已下发、但快照里还没反映出来的跳转目标（毫秒）。
  double? _pendingSeek;

  /// 锁住目标之后又轮询了几次：连续几次都追不上，说明这次跳转不会生效了。
  int _pendingPolls = 0;

  /// 快照位置与目标差多少就算「追上了」：精确跳转只能落在帧 / 包边界上。
  static const double _seekToleranceMs = 400;

  /// 兜底：连续这么多次轮询（约 3 秒）都没追上，就把控制权交还给轮询值。
  static const int _seekGiveUpPolls = 6;

  @override
  void didUpdateWidget(SeekSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_pendingSeek == null) return;

    final snapshot = widget.snapshot;
    final previous = oldWidget.snapshot;
    // 换曲（自动续播 / 手动切歌）、停止、失败：这个目标已经没有意义了。
    if (snapshot.trackId != previous.trackId ||
        snapshot.state == PlayerState.stopped ||
        snapshot.state == PlayerState.failed) {
      _releasePendingSeek();
      return;
    }
    if ((snapshot.positionMs - _pendingSeek!).abs() <= _seekToleranceMs) {
      _releasePendingSeek();
      return;
    }
    // 只有真正的新一轮轮询才计数（父级的其它重建会复用同一个快照对象）。
    if (!identical(snapshot, previous)) {
      _pendingPolls += 1;
      if (_pendingPolls >= _seekGiveUpPolls) {
        _releasePendingSeek();
      }
    }
  }

  /// 交还控制权：之后进度条重新跟随轮询值。
  void _releasePendingSeek() {
    _pendingSeek = null;
    _pendingPolls = 0;
  }

  /// 松手：先锁住目标，再通知外部跳转（顺序不能反，否则中间那次刷新会闪回旧位置）。
  void _commitSeek(double value) {
    setState(() {
      _dragging = null;
      _pendingSeek = value;
      _pendingPolls = 0;
    });
    widget.onSeek(value.round());
  }

  @override
  Widget build(BuildContext context) {
    final total = trackTotalMs(
      fromLibrary: widget.totalMs,
      fromEngine: widget.snapshot.durationMs,
    );
    // 两份都不知道时长时：不给拖动（滑到哪儿都没有意义），
    // 滑块也画成空的——`max` 只能给个占位值，`value` 必须跟着一起限制在
    // 同一个范围里。**这里踩过真机上的坑**：以前 `value` 用
    // `double.maxFinite` 当上界，于是「时长未知 + 已经在播」时
    // `value`（例如 20038）会大于 `max`（1），Flutter 直接断言失败，
    // 整个界面变成一屏红字。
    final max = total > 0 ? total.toDouble() : 1.0;
    // 拖动中跟手 → 刚跳转锁在目标 → 其余跟随轮询值。
    final shown =
        _dragging ?? _pendingSeek ?? widget.snapshot.positionMs.toDouble();
    final position = shown.clamp(0.0, max).toDouble();

    return Slider(
      onChanged: total > 0 ? (value) => setState(() => _dragging = value) : null,
      onChangeEnd: total > 0 ? _commitSeek : null,
      value: total > 0 ? position : 0,
      max: max,
    );
  }
}
