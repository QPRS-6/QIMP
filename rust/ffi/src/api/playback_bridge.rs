//! 原生侧（Android 通知栏 / 前台服务）需要的播放信息与操作。
//!
//! 为什么单独抽这一层：JNI 那一层只在 Android 上编译，能测的只有这里，
//! 所以「取什么值、怎么换算」的逻辑必须留在这边，JNI 只做转发。
//! 真正的状态仍然来自 `musicplayer-audio`（引擎）与 `musicplayer-core`（曲库）。

use musicplayer_audio::PlayerState;

use crate::api::{library, player};

/// 播放状态编码。与 Kotlin 侧 `PlaybackBridge.STATE_*` 一一对应，改动要两边一起改。
pub const STATE_STOPPED: i32 = 0;
pub const STATE_PLAYING: i32 = 1;
pub const STATE_PAUSED: i32 = 2;
pub const STATE_FAILED: i32 = 3;

/// 引擎当前状态；引擎没起来时按“已停止”处理（通知栏据此收掉自己）。
pub fn state_code() -> i32 {
    match player::snapshot_or_none().map(|snapshot| snapshot.state) {
        Some(PlayerState::Playing) => STATE_PLAYING,
        Some(PlayerState::Paused) => STATE_PAUSED,
        Some(PlayerState::Failed) => STATE_FAILED,
        Some(PlayerState::Stopped) | None => STATE_STOPPED,
    }
}

/// 当前位置（毫秒）。引擎没起来时返回 0。
pub fn position_ms() -> i64 {
    player::snapshot_or_none().map_or(0, |snapshot| snapshot.position_ms as i64)
}

/// 当前曲目 id；`0` 表示没有播放项。
pub fn track_id() -> i64 {
    player::snapshot_or_none().map_or(0, |snapshot| snapshot.track_id)
}

/// 当前曲目标题（按 id 查曲库）；查不到返回空串。
pub fn track_title() -> String {
    current_track().map_or_else(String::new, |track| track.title)
}

/// 当前曲目的艺术家；没有标签时返回空串。
pub fn track_artist() -> String {
    current_track()
        .and_then(|track| track.artist)
        .unwrap_or_default()
}

/// 当前曲目时长（毫秒）；查不到返回 0（通知栏据此不显示进度）。
pub fn track_duration_ms() -> i64 {
    // 时长不可能接近 i64 上限，放心转换（JNI 那边的 jlong 是有符号的）。
    current_track().map_or(0, |track| track.duration_ms as i64)
}

/// 引擎是否已经初始化。App 还没走到 `open_player` 时，通知栏不该显示任何东西。
pub fn engine_ready() -> bool {
    player::engine().is_ok()
}

/// 播放中的曲目播放失败的原因（给通知栏显示“播不了：…”）；没有则返回空串。
pub fn error_text() -> String {
    player::snapshot_or_none()
        .and_then(|snapshot| snapshot.error)
        .unwrap_or_default()
}

/// 当前曲目在曲库里的记录。引擎没起来、或这首歌还没入库时返回 `None`。
fn current_track() -> Option<musicplayer_core::Track> {
    let id = track_id();
    if id <= 0 {
        return None;
    }
    library::track_or_none(id)
}

/// 播放 / 暂停 / 切歌等操作。返回是否成功——失败只用来打日志，不影响通知栏。
fn run(action: impl FnOnce(&musicplayer_audio::Engine) -> musicplayer_audio::Result<()>) -> bool {
    match player::engine() {
        Ok(engine) => action(&engine).is_ok(),
        Err(_) => false,
    }
}

pub fn play() -> bool {
    run(|engine| engine.play())
}

pub fn pause() -> bool {
    run(|engine| engine.pause())
}

pub fn toggle() -> bool {
    run(|engine| engine.toggle())
}

pub fn next() -> bool {
    run(|engine| engine.next())
}

pub fn previous() -> bool {
    run(|engine| engine.previous())
}

/// 跳转（毫秒）。负值按 0 处理——JNI 那边拿到的是 Kotlin 的 `Long`。
pub fn seek_to(position_ms: i64) -> bool {
    run(|engine| engine.seek(position_ms.max(0) as u64))
}

/// 停止播放（通知栏上的“停止”/服务退出时用）。
pub fn stop() -> bool {
    run(|engine| engine.stop())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 引擎没起来时所有取值接口都要给“空”而不是崩：通知栏在 App 刚启动、
    /// 还没 open_player 的时候也可能被拉起来。
    #[test]
    fn values_are_empty_without_engine() {
        assert!(!engine_ready());
        assert_eq!(state_code(), STATE_STOPPED);
        assert_eq!(position_ms(), 0);
        assert_eq!(track_id(), 0);
        assert!(track_title().is_empty());
        assert!(track_artist().is_empty());
        assert_eq!(track_duration_ms(), 0);
        assert!(error_text().is_empty());
    }

    /// 没引擎时操作返回失败，而不是 panic。
    #[test]
    fn actions_fail_without_engine() {
        assert!(!play());
        assert!(!pause());
        assert!(!toggle());
        assert!(!next());
        assert!(!previous());
        assert!(!seek_to(1_000));
        assert!(!stop());
    }
}
