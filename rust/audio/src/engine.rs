//! 播放引擎：一个专用播放线程 + 一份共享快照。
//!
//! 为什么是「一个线程」而不是「回调里干活」：
//! - 音频回调里禁止加锁 / 分配内存 / 读文件，所以解码必须在别的线程上做；
//! - 把解码、队列、推进逻辑都放在同一个线程里，顺序问题（跳转、切歌、暂停）
//!   就退化成普通的同步代码，不需要满屏的原子变量和锁。
//! - FFI 侧只读 [`Shared`] 里的原子快照，永远不阻塞播放线程。

use std::sync::atomic::{AtomicI64, AtomicU64, AtomicU8, AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, Sender, TryRecvError};
use std::sync::{mpsc, Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use ringbuf::traits::Producer;
use ringbuf::HeapProd;

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

        let Some(chunk) = self.decoder.next_chunk()? else {
            self.source_done = true;
            return Ok(FillOutcome::Finished);
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
    fn seek(&mut self, position_ms: u64, output: &AudioOutputHandle) -> Result<()> {
        let actual = self.decoder.seek(position_ms)?;

        let (producer, consumer) = ring_buffer(self.spec);
        let played = {
            let mut guard = lock_output(output)?;
            guard.start(self.spec, consumer)?;
            guard.played_frames()
        };

        self.producer = producer;
        self.played = played;
        self.base_ms = actual;
        self.base_frames = 0;
        self.mapped.clear();
        self.pending = 0;
        self.samples_written = 0;
        self.source_done = false;
        Ok(())
    }

    /// 当前播放位置（毫秒）：以音频线程真正播出多少帧为准。
    fn position_ms(&self) -> u64 {
        let played = self.played.load(Ordering::Relaxed);
        let delta = played.saturating_sub(self.base_frames);
        self.base_ms + delta * 1000 / u64::from(self.spec.sample_rate.max(1))
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
    pub repeat: RepeatMode,
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
    repeat: AtomicU8,
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
    SetRepeat(RepeatMode),
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

    pub fn set_repeat(&self, mode: RepeatMode) -> Result<()> {
        self.send(Command::SetRepeat(mode))
    }

    /// 读取当前状态快照；不阻塞播放线程。
    pub fn snapshot(&self) -> PlayerSnapshot {
        PlayerSnapshot {
            state: self.shared.state(),
            position_ms: self.shared.position_ms.load(Ordering::Relaxed),
            index: self.shared.index.load(Ordering::Relaxed) as u32,
            queue_len: self.shared.queue_len.load(Ordering::Relaxed) as u32,
            track_id: self.shared.track_id.load(Ordering::Relaxed),
            repeat: repeat_from_u8(self.shared.repeat.load(Ordering::Relaxed)),
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
fn start_session(
    item: &QueueItem,
    position_ms: u64,
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
    let played = {
        let mut guard = lock_output(output)?;
        guard.start(spec, consumer)?;
        guard.played_frames()
    };

    let mut session = Session {
        decoder,
        producer,
        played,
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
        session.seek(position_ms, output)?;
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
    match start_session(item, 0, output) {
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
                    if let Err(err) = current.seek(0, output) {
                        shared.fail(err.to_string());
                        *state = PlayerState::Failed;
                    }
                }
            }
        },
        Command::Seek(position_ms) => {
            if let Some(current) = session.as_mut() {
                if let Err(err) = current.seek(position_ms, output) {
                    shared.fail(err.to_string());
                    *state = PlayerState::Failed;
                }
            }
        }
        Command::SetRepeat(mode) => queue.set_repeat(mode),
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
    match session {
        Some(current) => {
            shared
                .position_ms
                .store(current.position_ms(), Ordering::Relaxed);
            shared.track_id.store(current.track_id, Ordering::Relaxed);
        }
        None => {
            shared.position_ms.store(0, Ordering::Relaxed);
            shared.track_id.store(0, Ordering::Relaxed);
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
    use crate::test_support::write_wav;

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

    /// 造一首真实的临时音频，返回入队项。
    fn wav_item(dir: &std::path::Path, name: &str, seconds: u32, id: i64) -> QueueItem {
        let path = dir.join(name);
        write_wav(&path, seconds);
        QueueItem::new(id, path.to_string_lossy().to_string())
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
