//! 纯本地音乐播放器 —— Rust 核心。
//!
//! 设计约束（重要）：
//! 1. 本 crate **不得**依赖任何 Android / JNI / Flutter 相关代码，因此可以在宿主机上
//!    直接 `cargo test`，无需 NDK。
//! 2. 所有对外类型均为普通数据结构 + `serde`，方便随后由 `flutter_rust_bridge` 生成绑定。
//! 3. 文件系统访问一律走显式传入的根目录列表，核心不关心这些目录是普通路径还是
//!    由 Android SAF 授权后映射出来的路径。

// 测试代码里 `unwrap()` / `expect()` 就是“断言失败时把错误打印出来”的最直接写法，
// 为它们写样板匹配只会淹没真正的失败信息；生产代码仍然禁止（见 Cargo.toml 的 lints）。
#![cfg_attr(test, allow(clippy::unwrap_used, clippy::expect_used))]

pub mod db;
pub mod error;
pub mod lyric;
pub mod metadata;
pub mod models;
pub mod playlist_file;
pub mod scan;

pub use db::Db;
pub use error::{CoreError, Result};
pub use lyric::{LyricLine, Lyrics};
pub use models::{
    Album, Artist, MediaKind, PlayState, Playlist, PlaylistFileFormat, PlaylistImport, QueueTrack,
    ResumePoint, ResumeQueue, ScanMode, ScanProgress, ScanSummary, SortKey, SortOrder, Stats,
    Track, MISSING_PREVIEW_LIMIT,
};
pub use scan::{default_audio_extensions, is_audio_path, media_kind, scan_roots, ScanOptions};

/// 核心版本号，用于在 Flutter 启动时验证 FFI 通道是否打通。
pub const CORE_VERSION: &str = env!("CARGO_PKG_VERSION");

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_is_not_empty() {
        assert!(!CORE_VERSION.is_empty());
    }
}
