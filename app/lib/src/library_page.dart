import 'dart:async';
// 「继续播放」要确认那首歌的文件还在：曲库里的记录可能已经过期（文件被删了
// 但还没重扫），那种“接着放”一启动就会在播放条上报错，不如直接不装。
import 'dart:io' show File;

// Flutter 的 material 也导出了一个 `RepeatMode`（重复动画用）。
// 这里要用的是播放器的循环模式，所以把 Flutter 那个藏起来，避免歧义。
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter/services.dart' show DeviceOrientation, SystemChrome;
import 'package:musicplayer/src/add_songs.dart';
import 'package:musicplayer/src/app_drawer.dart';
import 'package:musicplayer/src/app_info.dart';
import 'package:musicplayer/src/library_api.dart';
import 'package:musicplayer/src/library_bottom_bar.dart';
import 'package:musicplayer/src/library_dialogs.dart';
import 'package:musicplayer/src/my_music.dart';
import 'package:musicplayer/src/now_playing_bar.dart';
import 'package:musicplayer/src/playback_service.dart';
import 'package:musicplayer/src/playlist_api.dart';
import 'package:musicplayer/src/playlist_page.dart';
import 'package:musicplayer/src/player_page.dart';
import 'package:musicplayer/src/progress_api.dart';
import 'package:musicplayer/src/queue_store.dart';
import 'package:musicplayer/src/queue_view.dart';
import 'package:musicplayer/src/rust/api/library.dart';
import 'package:musicplayer/src/rust/api/player.dart';
import 'package:musicplayer/src/sleep_timer.dart';
import 'package:musicplayer/src/storage.dart';
import 'package:musicplayer/src/tablet_layout.dart';
import 'package:musicplayer/src/theme_page.dart';
import 'package:musicplayer/src/theme_settings.dart';
import 'package:musicplayer/src/track_actions.dart';
import 'package:musicplayer/src/track_list.dart';
import 'package:path_provider/path_provider.dart';

/// 曲库页：授权 → 打开数据库 → 扫描 → 列表 / 搜索。
///
/// 流程上区分两种“失败”：
/// - 没有存储权限：给一屏指引，点按钮跳系统设置；
/// - 其它异常：直接显示错误文本，避免用户面对一个白屏。

/// 权限查询的注入点：默认走真实 MethodChannel；测试里可替换成确定性的桩。
typedef AccessProbe = Future<bool> Function();

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    this.accessProbe = StorageAccess.granted,
    this.playlistApi = const PlaylistApi(),
    this.progressApi = const ProgressApi(),
    this.libraryApi = const LibraryApi(),
    this.themeSettings,
  });

  /// 返回 `true` 表示已获得存储访问权。
  final AccessProbe accessProbe;

  /// 播放列表的读写入口（抽屉 / 列表页用）；测试里换成内存桩。
  final PlaylistApi playlistApi;

  /// 「继续播放」的读写入口（启动时读、暂停 / 切歌 / 退到后台时写）；测试里换成桩。
  final ProgressApi progressApi;

  /// 曲库的读写入口（列表 / 搜索 / 统计 / 入库 / 移出 / 删文件）；测试里换成内存桩。
  final LibraryApi libraryApi;

  /// 外观设置（背景色）。不传时自己建一份默认的——只有测试会这么用，
  /// 真机上由 `main.dart` 建好（它要在跑第一帧前把上次的底色读回来）。
  final ThemeSettings? themeSettings;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> with WidgetsBindingObserver {
  /// `null` 表示还没查出来（首屏转圈）。
  bool? _hasAccess;
  bool _busy = false;
  String? _error;
  Stats? _stats;
  List<Track> _tracks = const <Track>[];
  List<String> _roots = const <String>[];
  final TextEditingController _search = TextEditingController();

  /// 抽屉里选中的主视图（主页 / 我的音乐 / 队列）。
  HomeView _view = HomeView.library;

  /// 当前打开的播放列表（抽屉高亮用；`null` = 不在任何列表里）。
  int? _playlistId;

  /// 多选模式：长按换成勾选，底部那条工具条换成删除动作。
  bool _selecting = false;

  /// 已勾选的曲目 id。存 id 不存下标——列表会被搜索过滤，下标靠不住。
  final Set<int> _selected = <int>{};

  /// **不带搜索过滤**的整份曲目。「我的音乐」的分组浏览用它：
  /// 搜索框里非空时 `_tracks` 只剩一半，分组会少一半的专辑。
  List<Track>? _allTracks;

  /// 当前播放队列（Dart 侧镜像）。队列视图读它，换队列的地方写它。
  final PlayQueueStore _queue = PlayQueueStore();

  /// 播放状态快照。只让底部播放条监听它，避免每 500ms 重建整个曲目列表。
  final ValueNotifier<PlayerSnapshot?> _player = ValueNotifier<PlayerSnapshot?>(
    null,
  );

  /// 正在播放的曲目（按 id 缓存），用于列表被搜索过滤时仍能在播放条上显示。
  int _playingTrackId = 0;
  Track? _playingTrack;

  Timer? _ticker;

  /// 轮询计数：每 4 次（约 2 秒）把播放进度写回曲库一次。
  int _ticks = 0;

  /// 上次写回曲库的进度。轮询几百毫秒一次，同一个位置不必反复写。
  int _savedTrackId = 0;
  int _savedPositionMs = -1;

  /// 上次落库的那份队列与当前项。
  ///
  /// 存的是**镜像本身**而不是它的内容：队列只在 `_queue.replace` 时换对象，
  /// 所以 `identical` 就能判断「这一队是不是刚换过」，比逐条比对便宜。
  List<QueueEntry>? _savedQueue;
  int _savedQueueIndex = -1;

  /// 跳转后的一次性补刷：`seek` 由播放线程异步执行，
  /// 立刻取到的快照还是旧位置（进度条那边会先把目标锁住）。
  Timer? _seekCatchUp;

  /// 定时播放（睡眠定时）。放在这一层而不是全屏播放界面里：
  /// 退出播放界面之后倒计时还得继续走。
  late final SleepTimer _sleepTimer;

  /// 背景色那些设置（主页右上角那颗调色板进的就是它）。
  late final ThemeSettings _theme;

  @override
  void initState() {
    super.initState();
    // 定时播放：到点暂停而不是停止——醒来后再点一下播放就能接着听。
    _sleepTimer = SleepTimer(onFire: () => _runPlayerAction(playerPause));
    _theme = widget.themeSettings ?? ThemeSettings();
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
  }

  /// 上一次下发给平台的方向偏好（见 [_applyOrientations]）。
  List<DeviceOrientation>? _appliedOrientations;

  /// 主页的方向：**手机上锁竖屏**，平板随意（见 [homeOrientations]）。
  ///
  /// 放在 `didChangeDependencies` 而不是 `initState`：判断要用窗口尺寸，那是
  /// MediaQuery 给的——这一刻才知道这是手机还是平板，窗口尺寸一变也会自动重算。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 播放界面压在主页上时不要下发：那一页的方向要能自由转（手机上横屏有专门的
    // 左右分栏版式），在这儿锁着就转不动了。回来时 `_openPlayer` 会再锁上。
    if (ModalRoute.of(context)?.isCurrent ?? true) {
      _applyOrientations(homeOrientations(MediaQuery.sizeOf(context)));
    }
  }

  /// 把方向偏好交给平台，但**只有真的变了才过一次通道**：
  /// `didChangeDependencies` 会被叫很多次，每次都发一条平台消息没有必要。
  void _applyOrientations(List<DeviceOrientation> wanted) {
    final applied = _appliedOrientations;
    final same =
        applied != null &&
        applied.length == wanted.length &&
        applied.every(wanted.contains);
    if (same) return;
    _appliedOrientations = List<DeviceOrientation>.of(wanted);
    SystemChrome.setPreferredOrientations(wanted);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 退出（含热重启）前最后写一次进度，下次打开才能接着放。
    _saveProgress();
    _ticker?.cancel();
    _seekCatchUp?.cancel();
    _sleepTimer.dispose();
    _player.dispose();
    _queue.dispose();
    _search.dispose();
    super.dispose();
  }

  /// 从系统授权页返回时触发：权限可能刚被授予，必须复查一次。
  ///
  /// 顺带在退到后台时把进度与播放设置落库：系统随时可能回收进程，不能只指望
  /// `dispose` ——它不保证会被调用。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _hasAccess == false) {
      _bootstrap();
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _saveProgress();
      _savePlaybackMode();
    }
  }

  Future<void> _bootstrap() async {
    try {
      if (!await widget.accessProbe()) {
        setState(() => _hasAccess = false);
        return;
      }
      // 数据库放应用私有目录：不需要权限，也不会被别的应用改动。
      final dir = await getApplicationSupportDirectory();
      openLibrary(dbPath: '${dir.path}/library.db');
      // 打开音频设备（幂等）。放在权限之后：没权限时不该占用音频设备。
      openPlayer();
      _roots = suggestScanRoots();
      _reload();
      // 接着上次的听：装进引擎但不播放，用户点一下才出声。
      _restoreLastPlayed();
      // 上次的随机 / 循环：退出时记下的，启动时照旧装回引擎。
      _restorePlaybackMode();
      // 播放进度由轮询快照提供：500ms 一次，肉眼看进度条足够顺滑。
      _ticker ??= Timer.periodic(const Duration(milliseconds: 500), (_) {
        _refreshPlayer();
        // 每 2 秒把进度落库：换歌 / 进程被杀时最多也就丢这两秒。
        if (++_ticks % 4 == 0) _saveProgress();
      });
      _refreshPlayer();
      setState(() {
        _hasAccess = true;
        _error = null;
      });
    } catch (e) {
      setState(() {
        _hasAccess = true;
        _error = '初始化失败：$e';
      });
    }
  }

  /// 读取**曲库**列表。本地 SQLite 查几千首是毫秒级，所以直接用同步接口，省掉一屏 loading。
  ///
  /// 搜索框为空时顺手把「整份曲库」也存下来（我的音乐 / 队列要按 id 回查标题）。
  /// 注意这里读的是曲库（`in_library = 1`）：扫描只建索引，收进来的歌才算数。
  void _reload() {
    final query = _search.text.trim();
    if (query.isEmpty) {
      final all = widget.libraryApi.tracks();
      _allTracks = all;
      _tracks = all;
    } else {
      _tracks = widget.libraryApi.search(query);
    }
    _stats = widget.libraryApi.stats();
    setState(() {});
  }

  /// 单独把整份曲库读一遍（切到「我的音乐」时用：可能启动时搜索框里就有词）。
  void _loadAllTracks() {
    try {
      final all = widget.libraryApi.tracks();
      _allTracks = all;
      setState(() {});
    } catch (e) {
      _toast('读取曲库失败：$e');
    }
  }

  /// 曲库被改动之后的统一刷新：列表、统计，以及「我的音乐」的分组缓存。
  void _refreshLibrary() {
    _allTracks = null;
    _reload();
    if (_view == HomeView.myMusic) _loadAllTracks();
  }

  Future<void> _scan({required bool full}) async {
    setState(() => _busy = true);
    try {
      final summary = await scanLibrary(
        roots: _roots,
        mode: full ? ScanMode.full : ScanMode.incremental,
      );
      // 索引变了：曲库列表、统计、分组缓存一起重读。
      _refreshLibrary();
      final text =
          '扫描完成：新增 ${summary.added}，更新 ${summary.updated}，'
          '移除 ${summary.removed}，跳过 ${summary.skipped}，'
          '耗时 ${summary.elapsedMs} ms';
      if (summary.added > 0) {
        // 新扫到的歌**不会**自己进曲库，所以顺手给个入口：不然用户扫完一场空，
        // 只会以为是扫描没生效。
        _toastAction(text, label: '挑歌入库', onPressed: _addSongs);
      } else {
        _toast(text);
      }
    } catch (e) {
      _toast('扫描失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// 带一个按钮的提示。扫描完把「挑歌入库」摆在手边用。
  void _toastAction(
    String message, {
    required String label,
    required VoidCallback onPressed,
  }) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 6),
        action: SnackBarAction(label: label, onPressed: onPressed),
      ),
    );
  }

  /// 轮询播放状态。引擎还没初始化时静默忽略——首屏可能还没走到 `openPlayer`。
  void _refreshPlayer() {
    try {
      final snapshot = playerSnapshot();
      _rememberPlayingTrack(snapshot);
      // 换歌 / 暂停要补写一次进度（比较的是上一份快照，所以得在赋值之前）。
      _saveProgressOnChange(snapshot);
      _player.value = snapshot;
      // 队列 / 当前项也可能刚变（用户点了某一首、或者自动播到了下一首）。
      _saveQueue();
    } catch (_) {
      // 忽略：下一轮会再试，不值得往界面上抛错误。
    }
  }

  /// 队列或当前项变了就把整份队列落库，下次启动才能整队接着放。
  ///
  /// 不并进 `_saveProgress`：那个每两秒跑一次，而队列几乎不变——整表重写没必要。
  /// 这里用「队列镜像是不是同一份 + 当前项是不是同一个」来判断，绝大多数轮询什么都不做。
  void _saveQueue({bool force = false}) {
    final entries = _queue.entries.value;
    if (entries.isEmpty) return;
    // 下标取引擎快照：它是唯一知道「自动播到第几首了」的地方。
    // （刚 `setPlayQueue` 完的那 500ms 里快照可能还是上一首，下一轮就会改回来。）
    final index = (_player.value?.index ?? 0).clamp(0, entries.length - 1);
    if (!force &&
        identical(entries, _savedQueue) &&
        index == _savedQueueIndex) {
      return;
    }
    _savedQueue = entries;
    _savedQueueIndex = index;
    try {
      widget.progressApi.saveQueue(entries, index);
    } catch (_) {
      // 写不进去就等下一轮；为一次 SQLite 抖动弹提示只会打扰用户。
    }
  }

  /// 启动时把上次的**整份队列**装进引擎，但**不播放**。
  ///
  /// 装好之后底部播放条就会显示那一首与进度，点一下 ▶ 便从那儿接着放。
  /// 这也是它不用 `autoplay: true` 的原因：没人希望一打开应用就突然出声。
  ///
  /// 收的是整份队列，而不是「上次那一首」：只还原一首的话，重启之后
  /// 「下一曲」就是个死键（用户就是这么报上来的）。
  void _restoreLastPlayed() {
    final ResumeQueue? saved;
    try {
      saved = widget.progressApi.lastQueue();
    } catch (_) {
      return; // 读不到就当没有：接着放是锦上添花，不该拖累首屏
    }
    if (saved == null) return;

    // 曲库记录可能过期（文件被删了但还没重扫过）：那些条目剔掉，
    // 「上次那一首」跟着重新定位——细节在 `ProgressApi.plan` 里。
    final plan = ProgressApi.plan(
      saved: saved,
      exists: (path) => File(path).existsSync(),
    );
    if (plan == null) return;

    try {
      setPlayQueue(entries: plan.entries, startAt: plan.index, autoplay: false);
      // 队列镜像跟着走：抽屉里的「队列」与播放界面的半屏列表都读它。
      _queue.replace(plan.entries);
      playerLoad(
        positionMs: ProgressApi.startMsFor(
          positionMs: plan.positionMs,
          durationMs:
              _lookupTrack(plan.entries[plan.index].id)?.durationMs ?? 0,
        ),
      );
    } catch (_) {
      // 同上：装不上就当没这回事。
    }
  }

  /// 把当前的随机 / 循环设置落库（退到后台时调一次）。
  ///
  /// 只认播放快照：没有快照（引擎还没起来、初始化失败）就**什么都不写**——
  /// 拿一个「默认值」写进去，会把用户上次记下的那套盖掉，下次启动随机播放就
  /// 莫名其妙被关了。这个判断在 `ProgressApi.modeToSave` 里，那边有单测。
  void _savePlaybackMode() {
    final mode = ProgressApi.modeToSave(_player.value);
    if (mode == null) return;
    try {
      widget.progressApi.saveMode(shuffle: mode.shuffle, repeat: mode.repeat);
    } catch (_) {
      // 写不进去就等下一次退出；为一次 SQLite 抖动弹提示只会打扰用户。
    }
  }

  /// 把上次的随机 / 循环设置装回引擎（退出时由 [_savePlaybackMode] 落库）。
  ///
  /// 放在 [`_restoreLastPlayed`] **之后**：先把队装好，再设「怎么放」——
  /// `setShuffle` 会重开一轮随机播放并把当前这首记为「本轮已放过」，
  /// 队列还没装好的话，记下的就不是那一首了。
  ///
  /// 它只改设置、不出声：装完仍然停在暂停上，与「接着上次的听」一致。
  void _restorePlaybackMode() {
    final PlaybackMode? saved;
    try {
      saved = widget.progressApi.lastMode();
    } catch (_) {
      return; // 读不到就当默认（随机关、不循环）：锦上添花，不该拖累首屏
    }
    if (saved == null) return;

    try {
      playerSetShuffle(shuffle: saved.shuffle);
      playerSetRepeat(mode: saved.repeat);
    } catch (_) {
      // 同上：装不上就当没这回事。
    }
  }

  /// 换歌、以及「播放 → 别的状态」这两件事发生时补写一次进度。
  ///
  /// - 换歌：上一首停在哪儿也得记住（这一刻 `_player.value` 还是它）；
  /// - 暂停 / 停止：暂停那一刻的位置就是「上次听到哪儿」，不必等下一次轮询。
  void _saveProgressOnChange(PlayerSnapshot next) {
    final previous = _player.value;
    if (previous == null) return;
    final switched = previous.trackId != next.trackId;
    final paused =
        previous.state == PlayerState.playing &&
        next.state != PlayerState.playing;
    if (switched || paused) _saveProgress(force: true);
  }

  /// 把「现在听到哪儿了」写回曲库。
  ///
  /// 同一个位置不重复写：绝大多数调用来自几百毫秒一次的轮询。
  void _saveProgress({bool force = false}) {
    final snapshot = _player.value;
    final trackId = snapshot?.trackId ?? 0;
    if (trackId <= 0) return;
    final positionMs = snapshot!.positionMs;
    if (!force && trackId == _savedTrackId && positionMs == _savedPositionMs) {
      return;
    }
    _savedTrackId = trackId;
    _savedPositionMs = positionMs;
    try {
      widget.progressApi.save(trackId, positionMs);
    } catch (_) {
      // 写不进去就等下一轮；为一次 SQLite 抖动弹提示只会打扰用户。
    }
  }

  /// 记住正在播放的曲目。
  ///
  /// 搜索会把列表过滤成不含正在播放的那首；此时播放条就查不到标题与时长，
  /// 进度条会瞬间失去刻度（滑块贴到最左边）。这里留一份缓存兜底。
  void _rememberPlayingTrack(PlayerSnapshot snapshot) {
    if (snapshot.trackId <= 0) {
      _playingTrackId = 0;
      _playingTrack = null;
      return;
    }
    if (snapshot.trackId == _playingTrackId) return;
    _playingTrackId = snapshot.trackId;
    _playingTrack = _lookupTrack(snapshot.trackId);
  }

  /// 统一的播放操作包装：出错提示用户，结束后刷新一次快照。
  ///
  /// `ensureService` 用于「可能会让声音响起来」的操作（播放 / 暂停 / 切歌）：
  /// 顺手确认一下前台服务在跑，否则息屏后系统随时会回收进程。
  void _runPlayerAction(void Function() action, {bool ensureService = false}) {
    if (ensureService) {
      PlaybackService.start();
    }
    try {
      action();
    } catch (e) {
      _toast('$e');
    }
    _refreshPlayer();
  }

  /// 从当前列表的第 `index` 首开始播放（列表本身就是播放队列）。
  void _playAt(int index) => _playTracks(_tracks, index);

  /// 播放一组曲目（从第 `index` 首开始）。
  ///
  /// 曲库页、专辑/艺术家页、播放列表页都走这里：换队列的地方只该有一处，
  /// 队列镜像（抽屉里的「队列」视图）也只在这里更新。
  void _playTracks(List<Track> tracks, int index) {
    if (tracks.isEmpty) return;
    // 用户点了某一首：此时 App 一定在前台，正好可以拉起前台服务。
    PlaybackService.start();
    try {
      final entries = queueEntriesOf(tracks);
      setPlayQueue(entries: entries, startAt: index, autoplay: true);
      _queue.replace(entries);
    } catch (e) {
      _toast('无法播放：$e');
    }
    _refreshPlayer();
  }

  /// 跳到队列里的某一首（队列本身不变，只换当前项）。
  void _jumpTo(int index) {
    final entries = _queue.entries.value;
    if (index < 0 || index >= entries.length) return;
    PlaybackService.start();
    try {
      setPlayQueue(entries: entries, startAt: index, autoplay: true);
    } catch (e) {
      _toast('无法播放：$e');
    }
    _refreshPlayer();
  }

  /// 切主视图（抽屉里点的那三个）。
  ///
  /// 顺手退出多选：曲库工具条只在主页出现，切走还留着选中状态的话，
  /// 回来时会看到一堆勾着、但已经想不起来为什么要勾的歌。
  void _selectView(HomeView view) {
    setState(() {
      _view = view;
      _selecting = false;
      _selected.clear();
    });
    if (view == HomeView.myMusic && _allTracks == null) {
      _loadAllTracks();
    }
  }

  /// 打开一个播放列表：列表页有自己的返回箭头与编辑模式，所以走路由压栈。
  void _openPlaylist(Playlist playlist) {
    setState(() => _playlistId = playlist.id);
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => PlaylistPage(
              playlist: playlist,
              player: _player,
              queue: _queue,
              api: widget.playlistApi,
            ),
          ),
        )
        .whenComplete(() {
          if (mounted) setState(() => _playlistId = null);
        });
  }

  /// 长按曲目：动作表（加入播放列表 / 从库中删除 / 从储存中删除）。
  Future<void> _trackActions(Track track) async {
    final result = await showTrackActions(
      context,
      track: track,
      libraryApi: widget.libraryApi,
      playlistApi: widget.playlistApi,
    );
    if (!result.changed || !mounted) return;
    _stopIfDeleted(result.deletedIds);
    _selected.clear();
    _refreshLibrary();
  }

  /// 「＋ 添加歌曲」：把扫到、但还没进曲库的歌挑进来。
  Future<void> _addSongs() async {
    final added = await showAddSongs(context, api: widget.libraryApi);
    if (added > 0 && mounted) _refreshLibrary();
  }

  /// 进 / 出多选模式。进来时从零开始，免得残留上一次的勾选。
  void _toggleSelecting() {
    setState(() {
      _selecting = !_selecting;
      _selected.clear();
    });
  }

  /// 勾上 / 取消一首。
  void _toggleSelected(Track track) {
    setState(() {
      if (!_selected.remove(track.id)) _selected.add(track.id);
    });
  }

  /// 全选 / 取消全选**当前列表**里的歌：搜索过滤过的话，就是过滤后的那些。
  void _selectAllVisible() {
    setState(() {
      if (_tracks.isNotEmpty && _selected.length >= _tracks.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(_tracks.map((track) => track.id));
      }
    });
  }

  /// 把选中的歌移出曲库（文件还在）。
  void _removeSelectedFromLibrary() {
    final ids = _selected.toList();
    if (ids.isEmpty) return;
    try {
      final count = widget.libraryApi.remove(ids);
      _toast('已从曲库移出 $count 首，文件还在');
    } catch (e) {
      _toast('移出失败：$e');
    }
    setState(() {
      _selecting = false;
      _selected.clear();
    });
    _refreshLibrary();
  }

  /// 把选中的歌从储存里删掉：先确认，再动手。
  Future<void> _deleteSelectedFromStorage() async {
    final ids = _selected.toList();
    if (ids.isEmpty) return;
    final ok = await confirmDeleteFromStorage(context, count: ids.length);
    if (!ok || !mounted) return;
    final deleted = await deleteTracksFromStorage(
      ScaffoldMessenger.of(context),
      widget.libraryApi,
      ids,
    );
    _stopIfDeleted(deleted);
    setState(() {
      _selecting = false;
      _selected.clear();
    });
    _refreshLibrary();
  }

  /// 删掉/移出的曲目里正好有正在放的那一首时，把播放停掉。
  ///
  /// 引擎手里的文件已经没了，让它继续“放”只会卡在报错上；停掉之后播放条
  /// 会退化成「没有在播放」，用户再点别的歌就行。
  void _stopIfDeleted(List<int> deletedIds) {
    if (deletedIds.isEmpty) return;
    if (!deletedIds.contains(_player.value?.trackId ?? 0)) return;
    _runPlayerAction(playerStop);
  }

  /// 跳转进度。播放线程消化口令是异步的，所以隔一小会儿再补一次快照，
  /// 让进度条尽快回到真实位置（进度条自己还有「追不上就解锁」的兜底）。
  void _seekTo(int positionMs) {
    _runPlayerAction(() => playerSeek(positionMs: positionMs));
    _seekCatchUp?.cancel();
    _seekCatchUp = Timer(const Duration(milliseconds: 120), _refreshPlayer);
  }

  /// 循环模式：关闭 → 列表循环 → 单曲循环 → 关闭。
  void _cycleRepeat() {
    const order = [RepeatMode.off, RepeatMode.all, RepeatMode.one];
    final current = _player.value?.repeat ?? RepeatMode.off;
    final next = order[(order.indexOf(current) + 1) % order.length];
    _runPlayerAction(() => playerSetRepeat(mode: next));
  }

  /// 随机播放开关。
  ///
  /// 与循环模式是两个独立的维度：随机决定「下一首是谁」，循环决定「一轮放完怎么办」，
  /// 两者可以同时生效（例如「随机 + 列表循环」＝ 每轮随机打乱、放完再重开一轮）。
  void _toggleShuffle() {
    final current = _player.value?.shuffle ?? false;
    _runPlayerAction(() => playerSetShuffle(shuffle: !current));
  }

  /// 打开全屏播放界面。
  ///
  /// 页面本身不持有播放状态：把同一个快照通知器与操作回调传进去，
  /// 于是它与底部播放条永远显示同一个状态、点哪边的按钮都算数。
  ///
  /// 顺带把主页那份「手机锁竖屏」放开：手机横过来时播放界面有一整套专门的
  /// 左右分栏版式（见 `player_page`），在主页这边锁着就转不动了。
  /// 回来再锁上——手机上横着的主页只是把列表压成一条。
  Future<void> _openPlayer() async {
    _applyOrientations(DeviceOrientation.values);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(
          player: _player,
          // 播放界面底部弹出的是同一份队列镜像：不需要它自己再维护一份。
          queue: _queue.entries,
          trackById: _trackById,
          onToggle: () => _runPlayerAction(playerToggle, ensureService: true),
          onNext: () => _runPlayerAction(playerNext, ensureService: true),
          onPrevious: () =>
              _runPlayerAction(playerPrevious, ensureService: true),
          onSeek: _seekTo,
          onJump: _jumpTo,
          onCycleRepeat: _cycleRepeat,
          onToggleShuffle: _toggleShuffle,
          sleepTimer: _sleepTimer,
        ),
      ),
    );
    if (!mounted) return;
    _applyOrientations(homeOrientations(MediaQuery.sizeOf(context)));
  }

  /// 按 id 在当前列表里找曲目（底部播放条显示标题用）。
  ///
  /// 列表被搜索过滤后可能找不到正在播放的那首，此时退回缓存的那一份。
  Track? _trackById(int? id) {
    if (id == null || id <= 0) return null;
    final found = _lookupTrack(id);
    if (found != null) return found;
    return id == _playingTrackId ? _playingTrack : null;
  }

  Track? _lookupTrack(int id) {
    for (final track in _tracks) {
      if (track.id == id) return track;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (_hasAccess == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_hasAccess == false) {
      return _PermissionPage(onGranted: _bootstrap);
    }
    if (_error != null) {
      return _ErrorPage(message: _error!, onRetry: _bootstrap);
    }
    return Scaffold(
      // 左侧抽屉：导航 + 播放列表管理。
      // 顶栏的汉堡按钮由 AppBar 自动生成（有 drawer 时默认就是 DrawerButton）。
      drawer: AppDrawer(
        view: _view,
        onSelectView: _selectView,
        playlistId: _playlistId,
        onSelectPlaylist: _openPlaylist,
        api: widget.playlistApi,
      ),
      appBar: AppBar(
        title: _viewTitle(),
        // 右上角常驻一颗「编辑主题」（背景颜色）。三块主视图共用这一条顶栏，
        // 所以换到「我的音乐」「队列」也还在——用户找它的时候不会扑空。
        actions: [ThemeButton(settings: _theme)],
      ),
      body: switch (_view) {
        HomeView.library => _buildLibraryBody(),
        HomeView.myMusic => MyMusicView(
          tracks: _allTracks ?? const <Track>[],
          player: _player,
          onPlay: _playTracks,
          loading: _allTracks == null,
        ),
        HomeView.queue => QueueView(
          queue: _queue.entries,
          player: _player,
          trackById: _trackById,
          onJump: _jumpTo,
        ),
      },
      // 底部：播放条 + （只在主页出现的）曲库工具条。
      //
      // 工具条压在播放条下方，是照参考图的排法：图标一行、统计一行，都在最底下。
      // 播放条那边要把自己的底部安全区关掉，否则两块各加一次，
      // 中间会空出一条谁也说不清干什么的缝。
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ValueListenableBuilder<PlayerSnapshot?>(
            valueListenable: _player,
            builder: (context, snapshot, _) => NowPlayingBar(
              snapshot: snapshot,
              track: _trackById(snapshot?.trackId),
              bottomSafeArea: _view != HomeView.library,
              // 这三个都可能让声音响起来：顺手确认前台服务在跑。
              onToggle: () =>
                  _runPlayerAction(playerToggle, ensureService: true),
              onNext: () => _runPlayerAction(playerNext, ensureService: true),
              onPrevious: () =>
                  _runPlayerAction(playerPrevious, ensureService: true),
              onSeek: _seekTo,
              onCycleRepeat: _cycleRepeat,
              onToggleShuffle: _toggleShuffle,
              onOpenPlayer: _openPlayer,
            ),
          ),
          if (_view == HomeView.library)
            LibraryBottomBar(
              stats: _stats,
              selecting: _selecting,
              selectedCount: _selected.length,
              totalCount: _tracks.length,
              onToggleSelect: _toggleSelecting,
              onAddSongs: _addSongs,
              onScanIncremental: () => _scanFromBar(full: false),
              onScanFull: () => _scanFromBar(full: true),
              onSelectAll: _selectAllVisible,
              onRemoveFromLibrary: _removeSelectedFromLibrary,
              onDeleteFromStorage: _deleteSelectedFromStorage,
            ),
        ],
      ),
    );
  }

  /// 「更多」里的两个扫描入口。正在扫的时候点第二下没有意义，直接无视。
  void _scanFromBar({required bool full}) {
    if (_busy) return;
    _scan(full: full);
  }

  /// 主页（曲库）的内容：搜索 + 曲目列表。
  ///
  /// 统计与那排操作图标都在底部工具条上（照参考图），这里只剩顶上那个搜索框
  /// ——搜索框的位置与长相没动。
  Widget _buildLibraryBody() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: TextField(
            controller: _search,
            onChanged: (_) => _reload(),
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search),
              hintText: '搜索标题 / 艺术家 / 专辑',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        Expanded(
          child: ValueListenableBuilder<PlayerSnapshot?>(
            valueListenable: _player,
            builder: (context, snapshot, _) => TrackList(
              tracks: _tracks,
              emptyHint: _emptyHint(),
              playingId: snapshot?.trackId ?? 0,
              // 正在播放的那首在列表里会被标出来
              playingState: snapshot?.state,
              selecting: _selecting,
              selectedIds: _selected,
              onPlay: _playAt,
              onToggleSelect: _toggleSelected,
              // 长按 → 动作表：添加到播放列表 / 从库中删除 / 从储存中删除
              onLongPress: _trackActions,
            ),
          ),
        ),
      ],
    );
  }

  /// 主页不显示标题（图片里就是只有汉堡按钮）；
  /// 另外两个视图用标题告诉用户「现在在哪」。
  Widget? _viewTitle() {
    switch (_view) {
      case HomeView.library:
        return null;
      case HomeView.myMusic:
        return const Text('我的音乐');
      case HomeView.queue:
        return const Text('队列');
    }
  }

  /// 列表空了该说什么。
  ///
  /// 三种情况分开说：没有可扫描的目录（权限 / 存储的事）、搜索没匹配上、
  /// 以及**曲库真的是空的**——最后这种要明确告诉用户去哪儿把歌收进来，
  /// 否则「扫完了却什么都没有」看起来就像坏了。
  String _emptyHint() {
    if (_roots.isEmpty) {
      return '没有找到可扫描的音乐目录。\n把你的音乐放进 /storage/emulated/0/Music 后回来重试。';
    }
    final query = _search.text.trim();
    if (query.isNotEmpty) {
      return '曲库里没有匹配「$query」的歌。';
    }
    return '曲库是空的。\n点下面的 ＋ 从扫到的文件里挑歌进来；\n还没扫过的话，先用 ⋮ → 全量扫描建立索引。';
  }
}

/// 没有存储权限时的引导页。
class _PermissionPage extends StatelessWidget {
  const _PermissionPage({required this.onGranted});

  final Future<void> Function() onGranted;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(kAppTitle)),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.folder_off_outlined, size: 48),
            const SizedBox(height: 16),
            Text('需要“所有文件访问”权限', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            const Text(
              '播放器要直接读取你存储里的音乐文件（解析标签与内嵌封面），因此需要该权限。\n\n'
              '它只用于扫描本地音乐；本应用不联网，也不上传任何数据。',
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: StorageAccess.request,
              icon: const Icon(Icons.settings),
              label: const Text('去授权'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => onGranted(),
              child: const Text('已授权，重新检查'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorPage extends StatelessWidget {
  const _ErrorPage({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(kAppTitle)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: () => onRetry(), child: const Text('重试')),
            ],
          ),
        ),
      ),
    );
  }
}

// 曲目列表已抽到 `track_list.dart`（`TrackList`）：多选模式那几行行为单独成文件后
// 才能在宿主机上验（曲库页要真 `.so` 才跑得起来）。
