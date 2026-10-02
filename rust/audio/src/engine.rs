//! 播放引擎：一个专用播放线程 + 一份共享快照。
//!
//! 为什么是「一个线程」而不是「回调里干活」：
//! - 音频回调里禁止加锁 / 分配内存 / 读文件，所以解码必须在别的线程上做；
//! - 把解码、队列、推进逻辑都放在同一个线程里，顺序问题（跳转、切歌、暂停）
//!   就退化成普通的同步代码，不需要满屏的原子变量和锁。
//! - FFI 侧只读 [`Shared`] 里的原子快照，永远不阻塞播放线程。

use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, AtomicU8, AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, Sender, TryRecvError};
use std::sync::{mpsc, Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use ringbuf::traits::Producer;
use ringbuf::{HeapCons, HeapProd};

use crate::decoder::AudioDecoder;
use crate::error::{AudioError, Result};
use crate::output::{ring_buffer, AudioOutput, AudioOutputHandle, OutputSpec};
use crate::queue::{PlayQueue, QueueItem, RepeatMode};

/// 当前正在播的一首。
struct Session {
    decoder: AudioDecoder,
    /// 环形缓冲的写入端；消费端在音频线程手里。
    producer: HeapProd<f32>,
    /// 已播出帧数（由音频线程累加）。
    played: Arc<AtomicU64>,
    spec: OutputSpec,
    /// 源文件的声道数（解码器给出，声道映射要用）。
    src_channels: usize,
    /// 声道映射后的交错采样；跨包复用。
    mapped: Vec<f32>,
    /// `mapped` 中已成功写入环形缓冲的采样数。
    pending: usize,
    /// 累计写入的采样数（换算成帧要除以声道数）。
    samples_written: u64,
    /// 解码是否已到文件尾。
    source_done: bool,
    /// 位置基准：`base_ms` 那一刻，输出已播 `base_frames` 帧。
    base_ms: u64,
    base_frames: u64,
    track_id: i64,
}

/// 一次填充的结果。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FillOutcome {
    /// 又塞进去一包。
    Filled,
    /// 环形缓冲满了：等音频线程取走一些再继续。
    RingFull,
    /// 源文件已到结尾（缓冲里可能还有没播完的数据）。
    Finished,
}

impl Session {
    fn frames_written(&self) -> u64 {
        self.samples_written / self.spec.samples_per_frame() as u64
    }

    /// 把 `mapped` 中尚未写入的部分推进环形缓冲；返回是否全部写完。
    fn push_pending(&mut self) -> bool {
        let samples_per_frame = self.spec.samples_per_frame();
        while self.pending < self.mapped.len() {
            let pushed = self.producer.push_slice(&self.mapped[self.pending..]);
            if pushed == 0 {
                return false;
            }
            self.pending += pushed;
            self.samples_written += pushed as u64 / samples_per_frame as u64;
        }
        true
    }

    /// 解一包 → 声道映射 → 写进环形缓冲。
    fn fill(&mut self) -> Result<FillOutcome> {
        // 上次没塞完的继续塞，绝不能丢掉，否则会听到“跳帧”。
        if !self.push_pending() {
            return Ok(FillOutcome::RingFull);
        }
        if self.source_done {
            return Ok(FillOutcome::Finished);
        }

        let chunk = match self.decoder.next_chunk() {
            Ok(Some(chunk)) => chunk,
            Ok(None) => {
                self.source_done = true;
                return Ok(FillOutcome::Finished);
            }
            // 文件被截断（下载没下完之类，手机音乐库里很常见）：已经解出来的部分照播，
            // 之后当作「这首放完了」，让队列继续往下走，而不是弹一条错误把播放卡住。
            Err(AudioError::Io(err)) if err.kind() == std::io::ErrorKind::UnexpectedEof => {
                self.source_done = true;
                return Ok(FillOutcome::Finished);
            }
            Err(err) => return Err(err),
        };
        map_channels(
            chunk,
            self.src_channels,
            self.spec.samples_per_frame(),
            &mut self.mapped,
        );
        self.pending = 0;

        if self.push_pending() {
            Ok(FillOutcome::Filled)
        } else {
            Ok(FillOutcome::RingFull)
        }
    }

    /// 跳转：解码器换位置 + 重建音频流（环形缓冲里的旧数据直接丢弃最干净）。
    ///
    /// `playing` 是**引擎此刻的状态**，必须原样传到设备侧（理由见 [`open_output`]）。
    /// 少了这一步，「暂停中调歌词」会把设备留在「在跑」上，而引擎以为自己还在暂停；
    /// 之后用户按播放时 `resume()` 就是对一条已经在跑的流再 `start()` 一次，
    /// 那首歌从此播不出来（快照里 `state = Failed`，界面上是「播不了：…」）。
    fn seek(&mut self, position_ms: u64, playing: bool, output: &AudioOutputHandle) -> Result<()> {
        let actual = self.decoder.seek(position_ms)?;

        let (producer, consumer) = ring_buffer(self.spec);
        // 先把新流接上再换自身状态：接不上（设备报错）时旧状态原样留着，调用方好收尾。
        self.attach(consumer, actual, playing, output)?;
        self.producer = producer;
        Ok(())
    }

    /// 把音频通路接上：`consumer` 交给音频线程，位置基准挪到 `base_ms`。
    ///
    /// 只有 `producer`/`consumer` 是**新的一对**时才该调用它——老缓冲里的数据必须整体
    /// 丢弃，接着用会让声音与位置对不上。新流开起来之后是继续跑还是按回暂停，由
    /// `playing` 决定（见 [`open_output`]）。
    fn attach(
        &mut self,
        consumer: HeapCons<f32>,
        base_ms: u64,
        playing: bool,
        output: &AudioOutputHandle,
    ) -> Result<()> {
        let played = open_output(self.spec, consumer, playing, output)?;

        self.played = played;
        self.base_ms = base_ms;
        self.base_frames = 0;
        self.mapped.clear();
        self.pending = 0;
        self.samples_written = 0;
        self.source_done = false;
        Ok(())
    }

    /// 把这一首标记成「已经到头了」。
    ///
    /// 跳转落到文件尾之后时用（见 [`is_past_end`]）：解码器那边给不出这个位置了，
    /// 但环形缓冲里还剩一小段没播完——按自然播完那条路走：先把它播完，
    /// 再让队列往下走。用户把进度条拖到最后，要的也正是这个。
    fn finish(&mut self) {
        self.source_done = true;
    }

    /// 当前播放位置（毫秒）：以音频线程真正播出多少帧为准。
    fn position_ms(&self) -> u64 {
        let played = self.played.load(Ordering::Relaxed);
        let delta = played.saturating_sub(self.base_frames);
        self.base_ms + delta * 1000 / u64::from(self.spec.sample_rate.max(1))
    }

    /// 当前曲目的总时长（毫秒，来自容器）；容器没写时为 0。
    fn duration_ms(&self) -> u64 {
        self.decoder.info().duration_ms
    }
}

/// 声道映射：把源采样对齐到输出设备的声道数。
///
/// 只支持 1 / 2 声道输出，规则固定且可预测：
/// - 一致：原样拷贝；
/// - 单声道 → 立体声：同一采样复制到两个声道；
/// - 立体声 → 单声道：取两声道平均，避免只留左声道时的“缺一半”听感；
/// - 多声道 → 立体声：取前两个声道（不做完整的 downmix，够用且不会引入相位问题）。
fn map_channels(source: &[f32], src_channels: usize, dst_channels: usize, out: &mut Vec<f32>) {
    out.clear();
    let src_channels = src_channels.max(1);
    let dst_channels = dst_channels.max(1);
    if src_channels == dst_channels {
        out.extend_from_slice(source);
        return;
    }

    out.reserve(source.len() / src_channels * dst_channels);
    for frame in source.chunks_exact(src_channels) {
        match (src_channels, dst_channels) {
            (1, dst) => out.extend(std::iter::repeat_n(frame[0], dst)),
            (2, 1) => out.push((frame[0] + frame[1]) * 0.5),
            (_, dst) => out.extend_from_slice(&frame[..dst.min(src_channels)]),
        }
    }
}

/// 播放状态。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum PlayerState {
    /// 没在播（队列空 / 手动停止 / 已播完）。
    Stopped = 0,
    Playing = 1,
    Paused = 2,
    /// 出错了，`error` 字段里有原因。
    Failed = 3,
}

impl PlayerState {
    fn from_u8(value: u8) -> Self {
        match value {
            1 => Self::Playing,
            2 => Self::Paused,
            3 => Self::Failed,
            _ => Self::Stopped,
        }
    }
}

/// 给 UI 看的快照（FFI 直接把这份结构体交给 Dart）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlayerSnapshot {
    pub state: PlayerState,
    /// 当前播放位置（毫秒）。
    pub position_ms: u64,
    /// 当前曲目在队列中的下标（无曲目时为 0）。
    pub index: u32,
    pub queue_len: u32,
    /// 当前曲目在曲库里的 id（`0` 表示没有）。UI 用它回查标题/艺术家。
    pub track_id: i64,
    /// 当前曲目的总时长（毫秒）：由解码器从容器里算出；`0` 表示容器没写。
    ///
    /// 与曲库里那份的关系：曲库那份来自标签解析，通常更权威（列表里显示的就是它），
    /// UI 应该在曲库那份为 `0` 时才用这里的值（见 `seek_slider.dart`）。
    pub duration_ms: u64,
    pub repeat: RepeatMode,
    /// 随机播放开关。它与 `repeat` 是两个独立的维度：随机决定「下一首是谁」，
    /// 循环决定「一轮放完怎么办」。
    pub shuffle: bool,
    /// 最近一次错误信息；`None` 表示一切正常。
    pub error: Option<String>,
}

/// 播放线程与外部共享的状态。全部是原子读，FFI 侧不会被阻塞。
#[derive(Debug, Default)]
struct Shared {
    state: AtomicU8,
    position_ms: AtomicU64,
    index: AtomicUsize,
    queue_len: AtomicUsize,
    track_id: AtomicI64,
    /// 当前曲目的总时长（毫秒，来自解码器）；没有会话时为 0。
    duration_ms: AtomicU64,
    repeat: AtomicU8,
    shuffle: AtomicBool,
    error: Mutex<Option<String>>,
}

impl Shared {
    fn set_state(&self, state: PlayerState) {
        self.state.store(state as u8, Ordering::Relaxed);
    }

    fn state(&self) -> PlayerState {
        PlayerState::from_u8(self.state.load(Ordering::Relaxed))
    }

    fn fail(&self, message: String) {
        if let Ok(mut slot) = self.error.lock() {
            *slot = Some(message);
        }
        self.set_state(PlayerState::Failed);
    }

    fn clear_error(&self) {
        if let Ok(mut slot) = self.error.lock() {
            *slot = None;
        }
    }
}

/// 播放线程要执行的指令。
#[derive(Debug)]
enum Command {
    /// 替换队列（`autoplay` 为真时立即从 `start_at` 开始播）。
    ReplaceQueue {
        items: Vec<QueueItem>,
        start_at: usize,
        autoplay: bool,
    },
    Play,
    Pause,
    Stop,
    /// `auto = true` 表示当前这首自然播完，需要遵循单曲循环。
    Advance {
        auto: bool,
    },
    Rewind,
    Seek(u64),
    /// 把当前这项装进引擎并定位到某个位置，但**先不出声**（「继续播放」用）。
    Load(u64),
    SetRepeat(RepeatMode),
    /// 打开 / 关闭随机播放。
    SetShuffle(bool),
    Quit,
}

/// 播放引擎句柄。可以自由克隆给 FFI 用（内部是 `Arc`）。
pub struct Engine {
    tx: Sender<Command>,
    shared: Arc<Shared>,
    thread: Option<JoinHandle<()>>,
}

impl Engine {
    /// 创建引擎并启动播放线程。
    ///
    /// `output` 由调用方提供：Android 上传入 Oboe 实现，测试里传入可手动泵采样的
    /// [`crate::output::NullOutput`]。
    pub fn new(output: AudioOutputHandle) -> Result<Self> {
        let (tx, rx) = mpsc::channel();
        let shared = Arc::new(Shared::default());
        let thread = {
            let shared = Arc::clone(&shared);
            thread::Builder::new()
                .name("player".to_string())
                .spawn(move || run(rx, shared, output))
                .map_err(|err| AudioError::Device(format!("创建播放线程失败: {err}")))?
        };
        Ok(Self {
            tx,
            shared,
            thread: Some(thread),
        })
    }

    fn send(&self, command: Command) -> Result<()> {
        self.tx
            .send(command)
            .map_err(|_| AudioError::Device("播放线程已退出".to_string()))
    }

    /// 替换队列；`autoplay` 为真时立即从 `start_at` 开始播放。
    pub fn replace_queue(
        &self,
        items: Vec<QueueItem>,
        start_at: usize,
        autoplay: bool,
    ) -> Result<()> {
        self.send(Command::ReplaceQueue {
            items,
            start_at,
            autoplay,
        })
    }

    pub fn play(&self) -> Result<()> {
        self.send(Command::Play)
    }

    pub fn pause(&self) -> Result<()> {
        self.send(Command::Pause)
    }

    /// 播放/暂停切换（UI 上的那个大按钮）。
    pub fn toggle(&self) -> Result<()> {
        if self.shared.state() == PlayerState::Playing {
            self.pause()
        } else {
            self.play()
        }
    }

    pub fn stop(&self) -> Result<()> {
        self.send(Command::Stop)
    }

    /// 下一首（用户主动点按，不受单曲循环影响）。
    pub fn next(&self) -> Result<()> {
        self.send(Command::Advance { auto: false })
    }

    pub fn previous(&self) -> Result<()> {
        self.send(Command::Rewind)
    }

    pub fn seek(&self, position_ms: u64) -> Result<()> {
        self.send(Command::Seek(position_ms))
    }

    /// 把队列当前项装进引擎、定位到 `position_ms`，但**先不出声**。
    ///
    /// 「继续播放」用：启动时让界面能显示上次那首与进度，用户点一下 ▶ 才接着放。
    /// 与 [`Engine::seek`] 的区别是它会在还没有会话时先建一个（`seek` 只动已经装好的），
    /// 建好之后输出被按在暂停上，所以不会漏出一小段声音。
    pub fn load(&self, position_ms: u64) -> Result<()> {
        self.send(Command::Load(position_ms))
    }

    pub fn set_repeat(&self, mode: RepeatMode) -> Result<()> {
        self.send(Command::SetRepeat(mode))
    }

    /// 打开 / 关闭随机播放。只影响「下一首是谁」，不改变当前正在放的那首。
    pub fn set_shuffle(&self, on: bool) -> Result<()> {
        self.send(Command::SetShuffle(on))
    }

    /// 读取当前状态快照；不阻塞播放线程。
    pub fn snapshot(&self) -> PlayerSnapshot {
        PlayerSnapshot {
            state: self.shared.state(),
            position_ms: self.shared.position_ms.load(Ordering::Relaxed),
            index: self.shared.index.load(Ordering::Relaxed) as u32,
            queue_len: self.shared.queue_len.load(Ordering::Relaxed) as u32,
            track_id: self.shared.track_id.load(Ordering::Relaxed),
            duration_ms: self.shared.duration_ms.load(Ordering::Relaxed),
            repeat: repeat_from_u8(self.shared.repeat.load(Ordering::Relaxed)),
            shuffle: self.shared.shuffle.load(Ordering::Relaxed),
            error: self.shared.error.lock().ok().and_then(|slot| slot.clone()),
        }
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        // 让播放线程收尾（关掉音频流），避免流泄漏。
        let _ = self.tx.send(Command::Quit);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

fn repeat_from_u8(value: u8) -> RepeatMode {
    match value {
        1 => RepeatMode::All,
        2 => RepeatMode::One,
        _ => RepeatMode::Off,
    }
}

fn repeat_to_u8(mode: RepeatMode) -> u8 {
    match mode {
        RepeatMode::Off => 0,
        RepeatMode::All => 1,
        RepeatMode::One => 2,
    }
}

/// 开一条输出流，并把它设成与引擎状态一致的「跑 / 停」；返回设备那边的已播帧计数。
///
/// 为什么要多这一步：`AudioOutput::start` 开的流**一定**是跑着的（设备侧接口就是如此，
/// 它总是先关掉旧流再开一条新的，没有「开好但先别动」这一档）。所以引擎处于暂停时，
/// 开完流必须紧跟一次 `pause()`，否则会留下「设备在跑、引擎以为在暂停」的两套状态。
/// 之后的 `resume()` 等于对一条已经在跑的流再 `start()` 一次，Oboe 那边要么直接报
/// 状态错、要么等状态变化等到超时——那首歌就再也播不出来（用户看到的是「播不了：…」）。
///
/// 暂停不下去就把流整个关掉：宁可下次重新开一条，也别把这条状态错位的流留给引擎。
fn open_output(
    spec: OutputSpec,
    consumer: HeapCons<f32>,
    playing: bool,
    output: &AudioOutputHandle,
) -> Result<Arc<AtomicU64>> {
    let mut guard = lock_output(output)?;
    guard.start(spec, consumer)?;
    if !playing {
        if let Err(err) = guard.pause() {
            guard.stop();
            return Err(err);
        }
    }
    Ok(guard.played_frames())
}

/// 这个跳转失败算不算「跳过头了」——目标落在文件里**真正有数据**的那一段之后。
///
/// 两种来源都是同一件事：**文件不完整**（下载没下完、拷贝被打断、从坏卡里拷出来的，
/// 手机上很常见）。文件头里的时长与索引是全的，后面那段数据却没有：
///
/// - `UnexpectedEof`：目标还在容器声明的时长之内，但文件里已经没有那段数据了
///   （索引指到的字节位置越过了文件尾）。真机上用户看到的是
///   「播不了：文件系统错误: unexpected end of file」。
/// - [`AudioError::SeekOutOfRange`]：目标连容器声明的时长都超了（标签里的时长比容器
///   还长时就是这样）。
///
/// 这两种都不该让这一首「播不了」：把进度条拖到最后的意思就是「这首到头了」，
/// 该做的是当作它放完了、让队列继续往下走。真该报错的是别的失败（解码器坏了、
/// 权限没了……），那种仍然照旧报出来。
fn is_past_end(err: &AudioError) -> bool {
    match err {
        AudioError::Io(err) => err.kind() == std::io::ErrorKind::UnexpectedEof,
        AudioError::SeekOutOfRange(_) => true,
        _ => false,
    }
}

/// 取输出设备锁。锁中毒说明别处 panic 过，按设备错误上报而不是再 panic 一次。
fn lock_output(
    output: &AudioOutputHandle,
) -> Result<std::sync::MutexGuard<'_, Box<dyn AudioOutput>>> {
    output
        .lock()
        .map_err(|_| AudioError::Device("输出设备状态异常（锁已中毒）".to_string()))
}

/// 错误信息里只放文件名：绝对路径不该出现在 UI 上（沿用 core 的约定）。
fn display_name(item: &QueueItem) -> &str {
    item.path.rsplit('/').next().unwrap_or(&item.path)
}

/// 建立一次播放会话：打开解码器 → 按源格式开流。
///
/// `playing` 决定这次会话是**开始播放**还是**装好但先不出声**（「继续播放」用后者）：
/// 暂停状态的会话，设备侧那一条流也会被按在暂停上，两边状态从第一刻就是一致的。
fn start_session(
    item: &QueueItem,
    position_ms: u64,
    playing: bool,
    output: &AudioOutputHandle,
) -> Result<Session> {
    let decoder = AudioDecoder::open(&item.path)?;
    let info = decoder.info();
    let spec = OutputSpec {
        sample_rate: info.sample_rate.max(1),
        // 单声道保持单声道，其余按立体声输出（更多声道在 map_channels 里取前两声道）。
        channels: info.channels.clamp(1, 2),
    };

    let (producer, consumer) = ring_buffer(spec);
    let mut session = Session {
        decoder,
        producer,
        // 占位：真值来自设备侧，由下面的 `seek` / `attach` 换掉。
        played: Arc::new(AtomicU64::new(0)),
        spec,
        src_channels: usize::from(info.channels.max(1)),
        mapped: Vec::new(),
        pending: 0,
        samples_written: 0,
        source_done: false,
        base_ms: 0,
        base_frames: 0,
        track_id: item.id,
    };

    if position_ms > 0 {
        // 跳转要丢弃整段缓冲，`seek` 会另建一对（上面这对用不上）。
        session.seek(position_ms, playing, output)?;
    } else {
        session.attach(consumer, 0, playing, output)?;
    }
    Ok(session)
}

/// 关流并丢掉当前会话。
fn stop_playback(session: &mut Option<Session>, output: &AudioOutputHandle) {
    session.take();
    if let Ok(mut guard) = output.lock() {
        guard.stop();
    }
}

/// 播放指定单曲；打不开时记录原因并停在错误状态，而不是让整个进程崩掉。
fn play_item(
    item: &QueueItem,
    session: &mut Option<Session>,
    state: &mut PlayerState,
    shared: &Shared,
    output: &AudioOutputHandle,
) {
    match start_session(item, 0, true, output) {
        Ok(new_session) => {
            *session = Some(new_session);
            *state = PlayerState::Playing;
            shared.clear_error();
        }
        Err(err) => {
            shared.fail(format!("{}: {err}", display_name(item)));
            stop_playback(session, output);
            *state = PlayerState::Failed;
        }
    }
}

/// 装载指定单曲但不播放：建会话、定位到 `position_ms`，设备侧一并按在暂停上。
///
/// 返回装载后的状态（成功就是 `Paused`）。失败的原因写进共享快照，与 [`play_item`] 一致。
fn prepare_item(
    item: &QueueItem,
    position_ms: u64,
    session: &mut Option<Session>,
    shared: &Shared,
    output: &AudioOutputHandle,
) -> PlayerState {
    match start_session(item, position_ms, false, output) {
        Ok(loaded) => {
            *session = Some(loaded);
            shared.clear_error();
            PlayerState::Paused
        }
        Err(err) => {
            shared.fail(format!("{}: {err}", display_name(item)));
            stop_playback(session, output);
            PlayerState::Failed
        }
    }
}

/// 从队列当前项开始播放；队列为空则停住。
fn play_current(
    queue: &PlayQueue,
    session: &mut Option<Session>,
    state: &mut PlayerState,
    shared: &Shared,
    output: &AudioOutputHandle,
) {
    match queue.current().cloned() {
        Some(item) => play_item(&item, session, state, shared, output),
        None => {
            stop_playback(session, output);
            *state = PlayerState::Stopped;
        }
    }
}

/// 处理一条指令。
fn handle_command(
    command: Command,
    queue: &mut PlayQueue,
    state: &mut PlayerState,
    session: &mut Option<Session>,
    shared: &Shared,
    output: &AudioOutputHandle,
) {
    match command {
        Command::Quit => {}
        Command::ReplaceQueue {
            items,
            start_at,
            autoplay,
        } => {
            stop_playback(session, output);
            queue.replace(items, start_at);
            shared.clear_error();
            *state = PlayerState::Stopped;
            if autoplay && !queue.is_empty() {
                play_current(queue, session, state, shared, output);
            }
        }
        Command::Play => {
            if session.is_none() {
                play_current(queue, session, state, shared, output);
            } else {
                match lock_output(output).and_then(|mut guard| guard.resume()) {
                    Ok(()) => {
                        shared.clear_error();
                        *state = PlayerState::Playing;
                    }
                    Err(err) => {
                        shared.fail(err.to_string());
                        *state = PlayerState::Failed;
                    }
                }
            }
        }
        Command::Pause => {
            if *state == PlayerState::Playing {
                match lock_output(output).and_then(|mut guard| guard.pause()) {
                    Ok(()) => *state = PlayerState::Paused,
                    Err(err) => {
                        shared.fail(err.to_string());
                        *state = PlayerState::Failed;
                    }
                }
            }
        }
        Command::Stop => {
            stop_playback(session, output);
            *state = PlayerState::Stopped;
        }
        Command::Advance { auto } => match queue.advance(auto).cloned() {
            Some(item) => play_item(&item, session, state, shared, output),
            None => {
                stop_playback(session, output);
                *state = PlayerState::Stopped;
            }
        },
        Command::Rewind => match queue.rewind().cloned() {
            Some(item) => play_item(&item, session, state, shared, output),
            None => {
                // 已经在第一首：回到开头重播，符合大多数播放器的习惯。
                if let Some(current) = session.as_mut() {
                    let playing = *state == PlayerState::Playing;
                    if let Err(err) = current.seek(0, playing, output) {
                        shared.fail(err.to_string());
                        *state = PlayerState::Failed;
                    }
                }
            }
        },
        Command::Seek(position_ms) => {
            if let Some(current) = session.as_mut() {
                // 「设备该不该跑」只认引擎此刻的状态：暂停中调歌词（点某一句跳过去）
                // 之后设备必须仍然停在暂停上，否则点播放会对一条已经在跑的流再开一次。
                let playing = *state == PlayerState::Playing;
                match current.seek(position_ms, playing, output) {
                    Ok(()) => {}
                    // 跳到文件尾之后（文件没下完，标签 / 容器里的时长比实际数据长）：
                    // 当作「这首到这儿就完了」。用户把进度条拖到最后要的就是换下一首，
                    // 弹一条错误把播放卡住反而是坏行为——真机上就是这么踩到的。
                    Err(err) if is_past_end(&err) => current.finish(),
                    Err(err) => {
                        shared.fail(err.to_string());
                        *state = PlayerState::Failed;
                    }
                }
            }
        }
        Command::Load(position_ms) => {
            // 换一项就是换一个会话：先关掉上一个（顺带丢弃环形缓冲里的旧数据）。
            stop_playback(session, output);
            *state = match queue.current().cloned() {
                Some(item) => prepare_item(&item, position_ms, session, shared, output),
                None => PlayerState::Stopped,
            };
        }
        Command::SetRepeat(mode) => queue.set_repeat(mode),
        Command::SetShuffle(on) => queue.set_shuffle(on),
    }
}

/// 把当前状态发布到共享快照（FFI 只读它，不会被播放线程阻塞）。
fn publish(shared: &Shared, state: PlayerState, queue: &PlayQueue, session: Option<&Session>) {
    shared.set_state(state);
    shared.queue_len.store(queue.len(), Ordering::Relaxed);
    shared.index.store(queue.index(), Ordering::Relaxed);
    shared
        .repeat
        .store(repeat_to_u8(queue.repeat()), Ordering::Relaxed);
    shared.shuffle.store(queue.shuffle(), Ordering::Relaxed);
    match session {
        Some(current) => {
            shared
                .position_ms
                .store(current.position_ms(), Ordering::Relaxed);
            shared.track_id.store(current.track_id, Ordering::Relaxed);
            shared
                .duration_ms
                .store(current.duration_ms(), Ordering::Relaxed);
        }
        None => {
            shared.position_ms.store(0, Ordering::Relaxed);
            shared.track_id.store(0, Ordering::Relaxed);
            shared.duration_ms.store(0, Ordering::Relaxed);
        }
    }
}

/// 播放线程主循环。
fn run(rx: Receiver<Command>, shared: Arc<Shared>, output: AudioOutputHandle) {
    let mut queue = PlayQueue::new();
    let mut state = PlayerState::Stopped;
    let mut session: Option<Session> = None;
    let mut quit = false;

    while !quit {
        // 1) 先把积压的指令处理完：用户的点击优先于继续解码。
        loop {
            match rx.try_recv() {
                Ok(Command::Quit) => {
                    quit = true;
                    break;
                }
                Ok(command) => {
                    handle_command(
                        command,
                        &mut queue,
                        &mut state,
                        &mut session,
                        &shared,
                        &output,
                    );
                }
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => {
                    quit = true;
                    break;
                }
            }
        }
        if quit {
            break;
        }

        // 2) 推进当前曲目。
        let mut advance = false;
        let mut failure: Option<String> = None;
        if state == PlayerState::Playing {
            match session.as_mut() {
                Some(current) => match current.fill() {
                    Ok(FillOutcome::Filled) => {}
                    Ok(FillOutcome::RingFull) => thread::sleep(Duration::from_millis(2)),
                    Ok(FillOutcome::Finished) => {
                        // 解码到头还不够：必须等音频线程把缓冲里的也播完才算这首结束。
                        if current.played.load(Ordering::Relaxed) >= current.frames_written() {
                            advance = true;
                        } else {
                            thread::sleep(Duration::from_millis(5));
                        }
                    }
                    Err(err) => failure = Some(err.to_string()),
                },
                // 队列里有歌却没有会话（例如刚被停下）：直接起播。
                None => advance = true,
            }
        } else {
            thread::sleep(Duration::from_millis(10));
        }

        if let Some(message) = failure {
            shared.fail(message);
            state = PlayerState::Failed;
            stop_playback(&mut session, &output);
        }

        // 3) 自动续播下一首。
        if advance {
            match queue.advance(true).cloned() {
                Some(item) => play_item(&item, &mut session, &mut state, &shared, &output),
                None => {
                    stop_playback(&mut session, &output);
                    state = PlayerState::Stopped;
                }
            }
        }

        // 4) 发布快照。
        publish(&shared, state, &queue, session.as_ref());
    }

    stop_playback(&mut session, &output);
}

impl std::fmt::Debug for Engine {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Engine")
            .field("state", &self.shared.state())
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use std::time::Instant;

    use super::*;
    use crate::output::NullOutput;
    use crate::test_support::{write_truncated_wav, write_wav};

    /// 建一个可手动泵采样的输出：只有它自己取走数据，播放线程才会继续解码，
    /// 于是整条链路的时间完全由测试控制，不依赖真实时钟。
    fn manual_output() -> AudioOutputHandle {
        crate::output::shared_output(Box::new(NullOutput::new()))
    }

    /// 取走 `frames` 帧（模拟音频线程）。
    fn pump(output: &AudioOutputHandle, frames: usize) {
        if let Ok(mut guard) = output.lock() {
            if let Some(null) = guard.as_any_mut().downcast_mut::<NullOutput>() {
                null.pump(frames);
            }
        }
    }

    /// 一边泵采样一边等条件成立；超时返回 `false`。
    fn pump_until(
        output: &AudioOutputHandle,
        timeout_ms: u64,
        mut condition: impl FnMut() -> bool,
    ) -> bool {
        let started = Instant::now();
        while started.elapsed().as_millis() < u128::from(timeout_ms) {
            pump(output, 512);
            if condition() {
                return true;
            }
            thread::sleep(Duration::from_millis(5));
        }
        false
    }

    /// 设备侧是不是被按在暂停上。
    ///
    /// 这条不变量正是本文件那两个「暂停中跳转」用例要盯的：引擎暂停时设备也必须停着。
    /// 设备在跑而引擎以为在暂停，用户点播放时 `resume()` 就成了对一条已经在跑的流再
    /// `start()` 一次——真机上那首歌就再也播不出来（`NullOutput` 会如实记账，
    /// 但它的 `resume` 不会像 Oboe 那样报错，所以这里直接查状态）。
    fn device_paused(output: &AudioOutputHandle) -> bool {
        let Ok(mut guard) = output.lock() else {
            return false;
        };
        match guard.as_any_mut().downcast_mut::<NullOutput>() {
            Some(null) => null.is_paused(),
            None => false,
        }
    }

    /// 造一首真实的临时音频，返回入队项。
    fn wav_item(dir: &std::path::Path, name: &str, seconds: u32, id: i64) -> QueueItem {
        let path = dir.join(name);
        write_wav(&path, seconds);
        QueueItem::new(id, path.to_string_lossy().to_string())
    }

    /// 仓库里那份「没下完」的样本：头部声明 4 秒，实际只有约 2 秒数据。
    ///
    /// 见 `rust/testdata/README.md`，由 `testdata/generate.sh` 用 ffmpeg 生成后入库。
    fn truncated_mp3() -> String {
        format!("{}/../testdata/truncated.mp3", env!("CARGO_MANIFEST_DIR"))
    }

    /// 播完一首自动接下一首，全部播完后状态回到 Stopped。
    #[test]
    fn plays_queue_in_order_then_stops() {
        let temp = tempfile::tempdir().expect("临时目录");
        let output = manual_output();
        let engine = Engine::new(Arc::clone(&output)).expect("创建引擎");

        engine
            .replace_queue(
                vec![
                    wav_item(temp.path(), "a.wav", 1, 1),
                    wav_item(temp.path(), "b.wav", 1, 2),
                ],
                0,
                true,
            )
            .expect("入队并播放");

        assert!(
            pump_until(&output, 3_000, || engine.snapshot().state
                == PlayerState::Playing),
            "应进入播放状态：{:?}",
            engine.snapshot()
        );
        assert_eq!(engine.snapshot().track_id, 1, "应先播第一首");
        assert_eq!(engine.snapshot().queue_len, 2);

        assert!(
            pump_until(&output, 5_000, || engine.snapshot().track_id == 2),
            "第一首播完应自动接第二首：{:?}",
            engine.snapshot()
        );
        assert_eq!(engine.snapshot().index, 1);

        assert!(
            pump_until(&output, 5_000, || engine.snapshot().state
                == PlayerState::Stopped),
            "全部播完应停止：{:?}",
            engine.snapshot()
        );
        assert_eq!(engine.snapshot().position_ms, 0, "停止后位置应归零");
    }

    /// 随机播放：打开开关后「下一首」会换到别的曲目（而不是下一首顺序上的那一首），
    /// 开关状态也出现在快照里。
    #[test]
    fn shuffle_next_moves_to_another_track() {
        let temp = tempfile::tempdir().expect("临时目录");
        let output = manual_output();
        let engine = Engine::new(Arc::clone(&output)).expect("创建引擎");
        engine
            .replace_queue(
                vec![
                    wav_item(temp.path(), "a.wav", 30, 1),
                    wav_item(temp.path(), "b.wav", 30, 2),
                    wav_item(temp.path(), "c.wav", 30, 3),
                ],
                0,
                true,
            )
            .expect("入队并播放");
        assert!(pump_until(&output, 3_000, || engine.snapshot().state
            == PlayerState::Playing));

        engine.set_shuffle(true).expect("打开随机播放");
        assert!(
            pump_until(&output, 2_000, || engine.snapshot().shuffle),
            "开关应出现在快照里：{:?}",
            engine.snapshot()
        );

        engine.next().expect("下一首");
        assert!(
            pump_until(&output, 2_000, || engine.snapshot().track_id != 1),
            "随机播放不该留在同一首上：{:?}",
            engine.snapshot()
        );
        assert_eq!(
            engine.snapshot().state,
            PlayerState::Playing,
            "换歌之后应该继续播放"
        );

        engine.set_shuffle(false).expect("关闭随机播放");
        assert!(
            pump_until(&output, 2_000, || !engine.snapshot().shuffle),
            "关掉之后快照应回到关闭状态"
        );
    }

    /// 暂停后位置冻结，恢复后继续前进。
    #[test]
    fn pause_freezes_position_until_resumed() {
        let temp = tempfile::tempdir().expect("临时目录");
        let output = manual_output();
        let engine = Engine::new(Arc::clone(&output)).expect("创建引擎");
        engine
            .replace_queue(vec![wav_item(temp.path(), "long.wav", 30, 7)], 0, true)
            .expect("播放");

        assert!(
            pump_until(&output, 3_000, || engine.snapshot().position_ms > 0),
            "进度应开始增长"
        );

        engine.pause().expect("暂停");
        assert!(
            pump_until(&output, 2_000, || engine.snapshot().state
                == PlayerState::Paused),
            "应进入暂停状态：{:?}",
            engine.snapshot()
        );

        let frozen = engine.snapshot().position_ms;
        for _ in 0..20 {
            pump(&output, 512);
            thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(
            engine.snapshot().position_ms,
            frozen,
            "暂停期间位置不应增长"
        );

        engine.play().expect("恢复播放");
        assert!(
            pump_until(&output, 3_000, || engine.snapshot().position_ms > frozen),
            "恢复后位置应继续增长：{:?}",
            engine.snapshot()
        );
    }

    /// 引擎把解码器算出来的时长放进快照：曲库那份是 0 时（标签里读不出时长），
    /// UI 只能靠这个值把进度条画对。
    #[test]
    fn snapshot_reports_container_duration() {
        let temp = tempfile::tempdir().expect("临时目录");
        let output = manual_output();
        let engine = Engine::new(Arc::clone(&output)).expect("创建引擎");

        engine
            .replace_queue(vec![wav_item(temp.path(), "known.wav", 5, 3)], 0, true)
            .expect("入队并播放");

        assert!(
            pump_until(&output, 3_000, || engine.snapshot().duration_ms > 0),
            "应报出容器里的时长：{:?}",
            engine.snapshot()
        );
        let duration = engine.snapshot().duration_ms;
        assert!(
            (4_900..=5_100).contains(&duration),
            "5 秒的 WAV 应报 5000ms，实际 {duration}"
        );

        // 停下来之后不该再留着上一首的时长（否则会拿去画一首不存在的曲目）。
        engine.stop().expect("停止");
        assert!(
            pump_until(&output, 2_000, || engine.snapshot().state
                == PlayerState::Stopped),
            "应回到已停止：{:?}",
            engine.snapshot()
        );
        assert_eq!(engine.snapshot().duration_ms, 0);
    }

    /// 「继续播放」：装载后停在指定位置且不出声，点播放才从那儿接着放。
    #[test]
    fn load_prepares_paused_session_at_position() {
        let temp = tempfile::tempdir().expect("临时目录");
        let output = manual_output();
        let engine = Engine::new(Arc::clone(&output)).expect("创建引擎");
        // 先只入队不播放（启动时的状态就是这样），再把它装到 6 秒处。
        engine
            .replace_queue(vec![wav_item(temp.path(), "long.wav", 30, 5)], 0, false)
            .expect("入队");
        engine.load(6_000).expect("装载");

        assert!(
            pump_until(&output, 3_000, || engine.snapshot().state
                == PlayerState::Paused),
            "装载后应停在暂停状态：{:?}",
            engine.snapshot()
        );
        assert_eq!(engine.snapshot().track_id, 5, "应认出装的是哪一首");
        let loaded = engine.snapshot().position_ms;
        assert!(
            (5_500..=6_500).contains(&loaded),
            "应停在目标位置附近：{loaded}"
        );

        // 暂停着就不该自己往前走（既不出声也不解码）。
        for _ in 0..20 {
            pump(&output, 512);
            thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(
            engine.snapshot().position_ms,
            loaded,
            "装载后位置不该自己增长"
        );

        // 点播放：从装载的位置接着放，而不是回到开头。
        engine.play().expect("播放");
        assert!(
            pump_until(&output, 3_000, || engine.snapshot().state
                == PlayerState::Playing),
            "点了播放就该响：{:?}",
            engine.snapshot()
        );
        assert!(
            pump_until(&output, 3_000, || engine.snapshot().position_ms > loaded),
            "应从装载的位置继续：{:?}",
            engine.snapshot()
        );
    }

    /// 跳转后位置应落在目标附近，并且不倒退。
    #[test]
    fn seek_moves_position_near_target() {
        let temp = tempfile::tempdir().expect("临时目录");
        let output = manual_output();
        let engine = Engine::new(Arc::clone(&output)).expect("创建引擎");
        engine
            .replace_queue(vec![wav_item(temp.path(), "long.wav", 30, 9)], 0, true)
            .expect("播放");

        assert!(pump_until(&output, 3_000, || engine.snapshot().position_ms > 0));

        engine.seek(5_000).expect("跳转");
        assert!(
            pump_until(&output, 3_000, || engine.snapshot().position_ms >= 4_500),
            "跳转后位置应在 5s 附近：{:?}",
            engine.snapshot()
        );
        assert!(
            engine.snapshot().position_ms < 6_000,
            "跳转不应越界到目标之后太多：{:?}",
            engine.snapshot()
        );
    }

    /// 暂停中调歌词（点某一句跳过去）：设备必须仍然停在暂停上，之后点播放要能接着响。
    ///
    /// 回归用例。跳转一定会重建输出流，而设备侧新开出来的流**就是跑着的**；少了
    /// 「引擎在暂停就把新流按回去」这一步，就变成「设备在跑、引擎以为在暂停」。
    /// 真机上点播放会对一条已经在跑的流再 `start()` 一次：Oboe 报状态错，那首歌从此
    /// 播不出来（界面上是「播不了：…」）。`NullOutput` 不会报错，但它如实记账，
    /// 所以这里直接查设备状态。
    #[test]
    fn seek_while_paused_keeps_device_paused_and_still_plays() {
        let temp = tempfile::tempdir().expect("临时目录");
        let output = manual_output();
        let engine = Engine::new(Arc::clone(&output)).expect("创建引擎");
        engine
            .replace_queue(vec![wav_item(temp.path(), "long.wav", 30, 11)], 0, true)
            .expect("播放");

        assert!(
            pump_until(&output, 3_000, || engine.snapshot().position_ms > 0),
            "进度应开始增长"
        );

        engine.pause().expect("暂停");
        assert!(
            pump_until(&output, 2_000, || engine.snapshot().state
                == PlayerState::Paused),
            "应进入暂停状态：{:?}",
            engine.snapshot()
        );
        assert!(device_paused(&output), "暂停之后设备也该停着");

        // 调歌词：跳到 10 秒那一句。
        engine.seek(10_000).expect("跳转");
        assert!(
            pump_until(&output, 3_000, || engine.snapshot().position_ms >= 9_500),
            "跳转后位置应落在 10s 附近：{:?}",
            engine.snapshot()
        );
        assert!(
            device_paused(&output),
            "暂停中的跳转不能把设备流唤醒：之后点播放会对一条已经在跑的流再开一次"
        );

        // 暂停着就不该自己往前走（跳转完也一样）。
        let frozen = engine.snapshot().position_ms;
        for _ in 0..20 {
            pump(&output, 512);
            thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(
            engine.snapshot().position_ms,
            frozen,
            "暂停期间跳转之后位置也不该自己增长"
        );

        // 点播放：从跳转到的位置接着响，而且不能记下错误。
        engine.play().expect("播放");
        assert!(
            pump_until(&output, 3_000, || engine.snapshot().state
                == PlayerState::Playing),
            "点了播放就该响：{:?}",
            engine.snapshot()
        );
        assert!(
            pump_until(&output, 3_000, || engine.snapshot().position_ms > frozen),
            "应从跳转到的位置继续往前走：{:?}",
            engine.snapshot()
        );
        assert_eq!(engine.snapshot().error, None, "整个过程都不该有错误");
    }

    /// 暂停中在**第一首**上按「上一曲」：引擎回到开头重播，这次跳转同样不能把设备唤醒。
    #[test]
    fn rewind_to_start_while_paused_keeps_device_paused() {
        let temp = tempfile::tempdir().expect("临时目录");
        let output = manual_output();
        let engine = Engine::new(Arc::clone(&output)).expect("创建引擎");
        engine
            .replace_queue(vec![wav_item(temp.path(), "long.wav", 30, 13)], 0, true)
            .expect("播放");

        // 先跳到 8 秒，这样「回到开头」在快照里看得见。
        assert!(
            pump_until(&output, 3_000, || engine.snapshot().position_ms > 0),
            "进度应开始增长"
        );
        engine.seek(8_000).expect("跳转");
        assert!(
            pump_until(&output, 3_000, || engine.snapshot().position_ms >= 7_500),
            "跳转后位置应在 8s 附近：{:?}",
            engine.snapshot()
        );

        engine.pause().expect("暂停");
        assert!(
            pump_until(&output, 2_000, || engine.snapshot().state
                == PlayerState::Paused),
            "应进入暂停状态：{:?}",
            engine.snapshot()
        );

        engine.previous().expect("上一曲");
        assert!(
            pump_until(&output, 3_000, || engine.snapshot().position_ms < 1_000),
            "第一首上按「上一曲」应回到开头：{:?}",
            engine.snapshot()
        );
        assert!(
            device_paused(&output),
            "回到开头也是一次跳转，同样不能把设备流唤醒"
        );

        engine.play().expect("播放");
        assert!(
            pump_until(&output, 3_000, || engine.snapshot().state
                == PlayerState::Playing),
            "点了播放就该响：{:?}",
            engine.snapshot()
        );
        assert!(
            pump_until(&output, 3_000, || engine.snapshot().position_ms > 0),
            "应从头开始往前走：{:?}",
            engine.snapshot()
        );
    }

    /// 文件没下完（标签 / 容器里的时长比文件里实际的数据长）时，把进度条拖到最后
    /// 会跳到「不存在的那一段」上：这一首该当作放完了、让队列接着往下走，
    /// 而不是弹一条错误把播放卡住。
    ///
    /// 回归用例：真机上用户看到的是「播不了：文件系统错误: unexpected end of file」，
    /// 而且那首歌会一直卡在那儿。样本 `testdata/truncated.mp3` 声明 4 秒、
    /// 实际只有约 2 秒数据，跳到 2.5 秒必定落到缺失的那一段。
    #[test]
    fn seek_past_truncated_data_ends_track_instead_of_failing() {
        let temp = tempfile::tempdir().expect("临时目录");
        let output = manual_output();
        let engine = Engine::new(Arc::clone(&output)).expect("创建引擎");
        engine
            .replace_queue(
                vec![
                    QueueItem::new(1, truncated_mp3()),
                    wav_item(temp.path(), "next.wav", 30, 2),
                ],
                0,
                true,
            )
            .expect("入队并播放");

        assert!(
            pump_until(&output, 3_000, || engine.snapshot().position_ms > 0),
            "没下完的文件，已有的那部分应该照常播：{:?}",
            engine.snapshot()
        );

        engine.seek(2_500).expect("跳转口令");

        assert!(
            pump_until(&output, 5_000, || engine.snapshot().track_id == 2),
            "该当作这首放完了、接着放下一首，而不是停在这一首上：{:?}",
            engine.snapshot()
        );
        assert_eq!(
            engine.snapshot().error,
            None,
            "跳到文件尾之后不该被记成播放错误：{:?}",
            engine.snapshot()
        );
        assert_eq!(engine.snapshot().state, PlayerState::Playing);
    }

    /// 目标连容器声明的时长都超了（标签里的时长比容器还长时就是这样）：同样当作
    /// 「这首到头了」，不报错。
    #[test]
    fn seek_beyond_declared_duration_ends_track_instead_of_failing() {
        let temp = tempfile::tempdir().expect("临时目录");
        let output = manual_output();
        let engine = Engine::new(Arc::clone(&output)).expect("创建引擎");
        engine
            .replace_queue(
                vec![
                    QueueItem::new(1, truncated_mp3()),
                    wav_item(temp.path(), "next.wav", 30, 2),
                ],
                0,
                true,
            )
            .expect("入队并播放");

        assert!(
            pump_until(&output, 3_000, || engine.snapshot().position_ms > 0),
            "没下完的文件，已有的那部分应该照常播：{:?}",
            engine.snapshot()
        );

        // 样本容器声明 4 秒，60 秒连声明范围都超了。
        engine.seek(60_000).expect("跳转口令");

        assert!(
            pump_until(&output, 5_000, || engine.snapshot().track_id == 2),
            "超范围的目标也该当作这首放完了：{:?}",
            engine.snapshot()
        );
        assert_eq!(
            engine.snapshot().error,
            None,
            "超范围不该被记成播放错误：{:?}",
            engine.snapshot()
        );
    }

    /// 「跳过头了」只认这两种；别的失败（权限、解码器坏）仍然要如实报错。
    #[test]
    fn only_past_end_seek_errors_count_as_end_of_stream() {
        let eof = AudioError::Io(std::io::Error::new(
            std::io::ErrorKind::UnexpectedEof,
            "unexpected end of file",
        ));
        assert!(is_past_end(&eof), "文件里没这段数据：当作放完了");
        assert!(
            is_past_end(&AudioError::SeekOutOfRange("超了".to_string())),
            "目标超出容器声明范围：同样当作放完了"
        );

        let denied = AudioError::Io(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "permission denied",
        ));
        assert!(!is_past_end(&denied), "权限问题不能当成放完了");
        assert!(!is_past_end(&AudioError::Decode("解码器坏了".to_string())));
        assert!(!is_past_end(&AudioError::Device("设备没了".to_string())));
    }

    /// 文件被截断（下载没下完之类）：能播的部分照播，播完就当这首结束，
    /// 而不是弹一条错误把队列卡住。
    #[test]
    fn truncated_track_ends_instead_of_failing() {
        let temp = tempfile::tempdir().expect("临时目录");
        let path = temp.path().join("cut.wav");
        // 1 秒的文件砍掉尾部 3 KB（8kHz 8bit ≈ 0.38 秒）：解到末尾会读到 EOF。
        write_truncated_wav(&path, 1, 3_072);

        let output = manual_output();
        let engine = Engine::new(Arc::clone(&output)).expect("创建引擎");
        engine
            .replace_queue(
                vec![QueueItem::new(1, path.to_string_lossy().to_string())],
                0,
                true,
            )
            .expect("入队并播放");

        assert!(
            pump_until(&output, 5_000, || engine.snapshot().state
                == PlayerState::Stopped),
            "截断文件应正常播完：{:?}",
            engine.snapshot()
        );
        assert_eq!(engine.snapshot().error, None, "截断不该被当成播放错误");
    }

    /// 打不开的曲目要停在该曲目的错误状态并给出原因，而不是让进程崩掉。
    #[test]
    fn unplayable_track_reports_failure() {
        let output = manual_output();
        let engine = Engine::new(Arc::clone(&output)).expect("创建引擎");
        engine
            .replace_queue(vec![QueueItem::new(1, "/nonexistent/nope.mp3")], 0, true)
            .expect("入队");

        assert!(
            pump_until(&output, 3_000, || engine.snapshot().state
                == PlayerState::Failed),
            "应进入失败状态：{:?}",
            engine.snapshot()
        );
        let error = engine.snapshot().error.expect("应有错误信息");
        assert!(
            error.contains("nope.mp3"),
            "错误信息应指出是哪首歌：{error}"
        );
        assert!(
            !error.contains("/nonexistent"),
            "错误信息里不该出现绝对路径：{error}"
        );
    }
}
