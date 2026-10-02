//! 原生侧（Android 通知栏 / 前台服务）需要的播放信息与操作。
//!
//! 为什么单独抽这一层：JNI 那一层只在 Android 上编译，能测的只有这里，
//! 所以「取什么值、怎么换算」的逻辑必须留在这边，JNI 只做转发。
//! 真正的状态仍然来自 `musicplayer-audio`（引擎）与 `musicplayer-core`（曲库）。

use musicplayer_audio::{PlayerState, RepeatMode};

use crate::api::{library, player};

/// 播放状态编码。与 Kotlin 侧 `PlaybackBridge.STATE_*` 一一对应，改动要两边一起改。
pub const STATE_STOPPED: i32 = 0;
pub const STATE_PLAYING: i32 = 1;
pub const STATE_PAUSED: i32 = 2;
pub const STATE_FAILED: i32 = 3;

/// 循环模式编码。与 Kotlin 侧 `PlaybackBridge.REPEAT_*` 一一对应。
pub const REPEAT_OFF: i32 = 0;
pub const REPEAT_ALL: i32 = 1;
pub const REPEAT_ONE: i32 = 2;

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
///
/// 曲库里那份（标签解析来的）优先；它是 0 时退回解码器从容器里算出来的那份
/// ——有些文件标签里读不出时长却照样能播，那种情况下通知栏本来会一直没有进度条。
pub fn track_duration_ms() -> i64 {
    let Some(snapshot) = player::snapshot_or_none() else {
        return 0;
    };
    let from_library = track_by_id(snapshot.track_id).map_or(0, |track| track.duration_ms);
    if from_library > 0 {
        // 时长不可能接近 i64 上限，放心转换（JNI 那边的 jlong 是有符号的）。
        return from_library as i64;
    }
    snapshot.duration_ms as i64
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

/// 随机播放开着没有。桌面小部件要据此把那个图标点亮（通知栏不显示它）。
pub fn shuffle_on() -> bool {
    player::snapshot_or_none().is_some_and(|snapshot| snapshot.shuffle)
}

/// 当前循环模式的编码。
pub fn repeat_code() -> i32 {
    player::snapshot_or_none().map_or(REPEAT_OFF, |snapshot| i32::from(snapshot.repeat.code()))
}

/// 切换随机播放，返回切换**后**的状态（引擎没起来时是 `false`）。
///
/// 返回「切换后的状态」而不是「成功与否」：小部件点完要把图标画对，
/// 它需要的是那一个确定的值。
pub fn toggle_shuffle() -> bool {
    let Some(snapshot) = player::snapshot_or_none() else {
        return false;
    };
    let next = !snapshot.shuffle;
    run(|engine| engine.set_shuffle(next));
    next
}

/// 循环模式转一圈：关 → 全部循环 → 单曲循环 → 关，返回切换**后**的编码。
pub fn cycle_repeat() -> i32 {
    let Some(next) = player::snapshot_or_none().map(|snapshot| next_repeat(snapshot.repeat)) else {
        return REPEAT_OFF;
    };
    run(|engine| engine.set_repeat(next));
    i32::from(next.code())
}

/// 循环模式的下一档。
///
/// 顺序与界面上的「循环」按钮**必须一致**（`library_page.dart` 里那个 `order`），
/// 否则在小部件上点三下与在界面上点三下会落在不同的模式上。
fn next_repeat(current: RepeatMode) -> RepeatMode {
    match current {
        RepeatMode::Off => RepeatMode::All,
        RepeatMode::All => RepeatMode::One,
        RepeatMode::One => RepeatMode::Off,
    }
}

/// 当前曲目在曲库里的记录。引擎没起来、或这首歌还没入库时返回 `None`。
fn current_track() -> Option<musicplayer_core::Track> {
    track_by_id(track_id())
}

/// 按 id 取曲库记录；`0`（没有播放项）也当作查不到。
fn track_by_id(id: i64) -> Option<musicplayer_core::Track> {
    if id <= 0 {
        return None;
    }
    library::track_or_none(id)
}

/// 当前曲目的封面字节（内嵌图优先，其次同目录的 `cover.jpg` / `folder.jpg`，
/// 判断规则在 `metadata::read_cover` 里）；没有封面时返回空。
///
/// 通知栏 / 锁屏那一份封面只能由这里给：Flutter 引擎可能已经不在了
/// （用户把 App 从任务列表划掉），但正在放的那首的图照样得显示。
/// 曲目不在曲库里、没有封面、文件读不出来——统统给空：通知该做的是退化成没有图，
/// 而不是因为一张图整个显示不出来。
///
/// 给的是**原始字节**而不是 Bitmap：解码与缩放要用 `BitmapFactory`，
/// 那是 Android 的东西，core 一行都不该碰。
pub fn cover_bytes() -> Vec<u8> {
    let Some(track) = current_track() else {
        return Vec::new();
    };
    match musicplayer_core::metadata::read_cover(&track.path) {
        Ok(Some(cover)) => cover.data,
        _ => Vec::new(),
    }
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
        assert!(cover_bytes().is_empty(), "没有播放项时不该编一张封面出来");
        assert!(!shuffle_on(), "没有引擎时随机播放只能是关的");
        assert_eq!(repeat_code(), REPEAT_OFF);
    }

    /// 循环模式转一圈的顺序：与界面上的「循环」按钮一致（关 → 全部 → 单曲 → 关）。
    #[test]
    fn repeat_cycles_through_all_three_modes() {
        assert_eq!(next_repeat(RepeatMode::Off), RepeatMode::All);
        assert_eq!(next_repeat(RepeatMode::All), RepeatMode::One);
        assert_eq!(next_repeat(RepeatMode::One), RepeatMode::Off);
        // 绕一圈回到原点，界面才敢说「点几下就是哪个模式」。
        assert_eq!(
            next_repeat(next_repeat(next_repeat(RepeatMode::Off))),
            RepeatMode::Off
        );
    }

    #[test]
    fn repeat_codes_match_the_kotlin_constants() {
        assert_eq!(i32::from(RepeatMode::Off.code()), REPEAT_OFF);
        assert_eq!(i32::from(RepeatMode::All.code()), REPEAT_ALL);
        assert_eq!(i32::from(RepeatMode::One.code()), REPEAT_ONE);
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
        // 小部件上那两个开关在没引擎时也只是「什么也没发生」。
        assert!(!toggle_shuffle());
        assert_eq!(cycle_repeat(), REPEAT_OFF);
    }
}
