//! Flutter FFI 边界层。
//!
//! 职责划分（保持清晰）：
//! - `musicplayer-core`：全部业务逻辑（扫描 / 元数据 / 索引 / 歌词），纯 Rust、可单测。
//! - 本 crate：只做“翻译”，把 Dart 能理解的简单类型搬进搬出。
//!
//! `.so` 产物名叫 `libmusicplayer_ffi.so`（取自下方 `[lib] name`），Dart 侧生成的
//! 加载器正是按这个名字去找，所以**不要随意改 `[lib] name`**。
//!
//! 重新生成绑定（在 `app/` 下执行）：
//! ```bash
//! flutter_rust_bridge_codegen generate
//! ```
//!
//! 打 APK 前需要把 Rust 编成各 ABI 的 `.so`：
//! ```bash
//! cd rust && cargo ndk -t arm64-v8a -t x86_64 \
//!   -o ../app/android/app/src/main/jniLibs build --release -p musicplayer-ffi
//! ```

pub mod api;

/// 由 `flutter_rust_bridge_codegen generate` 生成，**不要手改**。
mod frb_generated;
