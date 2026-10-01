//! 播放接口：把 `musicplayer-audio` 的播放引擎暴露给 Dart。
//!
//! 状态获取方式是**轮询快照**（`player_snapshot`）而不是 Stream：
//! 进度条 200~500ms 刷一次足够，轮询实现简单、没有跨线程推送的生命周期问题；
//! 将来要做“精确到帧的进度动画”时，再把 core 已经留好的进度回调用 FRB Stream 暴露出来。

use std::sync::{Arc, Mutex};

use flutter_rust_bridge::frb;

use musicplayer_audio::{Engine, QueueItem};

// FRB 的 mirror 需要类型在本 crate 公开可见；这几个名字也决定了 Dart 侧的类型名。
pub use musicplayer_audio::{PlayerSnapshot, PlayerState, RepeatMode};

/// 进程内唯一的播放引擎。`None` 表示还没调用过 [`open_player`]。
static ENGINE: Mutex<Option<Arc<Engine>>> = Mutex::new(None);

/// 取引擎句柄。
pub(crate) fn engine() -> Result<Arc<Engine>, String> {
    ENGINE
        .lock()
        .map_err(|_| "播放引擎内部状态异常".to_string())?
        .clone()
        .ok_or_else(|| "播放引擎尚未初始化，请先调用 open_player".to_string())
}

/// 队列项：Dart 侧用曲库里的 id + 绝对路径构造。
#[derive(Debug, Clone)]
pub struct QueueEntry {
    pub id: i64,
    pub path: String,
}

/// 打开音频设备并启动播放线程。App 启动时调用一次，重复调用是安全的。
#[frb(sync)]
pub fn open_player() -> Result<(), String> {
    let mut guard = ENGINE
        .lock()
        .map_err(|_| "播放引擎内部状态异常".to_string())?;
    if guard.is_none() {
        let engine =
            Engine::new(musicplayer_audio::platform_output()).map_err(|e| e.to_string())?;
        *guard = Some(Arc::new(engine));
    }
    Ok(())
}

/// 替换播放队列。`start_at` 是起始下标，`autoplay` 决定是否立刻开始播放。
#[frb(sync)]
pub fn set_play_queue(
    entries: Vec<QueueEntry>,
    start_at: u32,
    autoplay: bool,
) -> Result<(), String> {
    let items = entries
        .into_iter()
        .map(|entry| QueueItem::new(entry.id, entry.path))
        .collect();
    engine()?
        .replace_queue(items, start_at as usize, autoplay)
        .map_err(|e| e.to_string())
}

#[frb(sync)]
pub fn player_play() -> Result<(), String> {
    engine()?.play().map_err(|e| e.to_string())
}

#[frb(sync)]
pub fn player_pause() -> Result<(), String> {
    engine()?.pause().map_err(|e| e.to_string())
}

/// 播放 / 暂停切换（界面上那个大按钮）。
#[frb(sync)]
pub fn player_toggle() -> Result<(), String> {
    engine()?.toggle().map_err(|e| e.to_string())
}

#[frb(sync)]
pub fn player_stop() -> Result<(), String> {
    engine()?.stop().map_err(|e| e.to_string())
}

#[frb(sync)]
pub fn player_next() -> Result<(), String> {
    engine()?.next().map_err(|e| e.to_string())
}

#[frb(sync)]
pub fn player_previous() -> Result<(), String> {
    engine()?.previous().map_err(|e| e.to_string())
}

#[frb(sync)]
pub fn player_seek(position_ms: u64) -> Result<(), String> {
    engine()?.seek(position_ms).map_err(|e| e.to_string())
}

#[frb(sync)]
pub fn player_set_repeat(mode: RepeatMode) -> Result<(), String> {
    engine()?.set_repeat(mode).map_err(|e| e.to_string())
}

/// 打开 / 关闭随机播放。与循环模式相互独立：随机决定「下一首是谁」，
/// 循环决定「一轮放完怎么办」。
#[frb(sync)]
pub fn player_set_shuffle(shuffle: bool) -> Result<(), String> {
    engine()?.set_shuffle(shuffle).map_err(|e| e.to_string())
}

/// 读取播放状态快照。UI 定时调用它刷新进度与状态。
#[frb(sync)]
pub fn player_snapshot() -> Result<PlayerSnapshot, String> {
    Ok(engine()?.snapshot())
}

/// 给非 Dart 的 FFI 使用者（Android 通知栏 / 前台服务）读快照：
/// 引擎没起来时返回 `None`，避免它们各自处理一遍错误。
pub(crate) fn snapshot_or_none() -> Option<PlayerSnapshot> {
    engine().ok().map(|engine| engine.snapshot())
}

// ---------------------------------------------------------------------------
// 镜像声明：Dart 直接使用 audio crate 的类型。
// 字段与源类型不一致会编译报错，所以这里不会悄悄跑偏。
// ---------------------------------------------------------------------------

/// [`musicplayer_audio::PlayerState`] 的镜像。
#[frb(mirror(PlayerState))]
pub enum _PlayerState {
    Stopped,
    Playing,
    Paused,
    Failed,
}

/// [`musicplayer_audio::RepeatMode`] 的镜像。
#[frb(mirror(RepeatMode))]
pub enum _RepeatMode {
    Off,
    All,
    One,
}

/// [`musicplayer_audio::PlayerSnapshot`] 的镜像。
#[frb(mirror(PlayerSnapshot))]
pub struct _PlayerSnapshot {
    pub state: PlayerState,
    pub position_ms: u64,
    pub index: u32,
    pub queue_len: u32,
    pub track_id: i64,
    pub repeat: RepeatMode,
    pub shuffle: bool,
    pub error: Option<String>,
}
