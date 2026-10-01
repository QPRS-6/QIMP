//! 暴露给 Dart 的接口层。
//!
//! 这里只做“翻译”：把 Dart 传入的简单参数转成 `musicplayer-core` 的调用，
//! 再把结果转回 FRB 能理解的基础类型。业务逻辑一律不写在这里。
//!
//! 命名注意：**不要**把子模块叫 `core`，那会在本模块内遮蔽 Rust 的 `core` crate。

pub mod app;

pub mod library;

/// JNI 接口（给 Android 前台服务 / 通知栏用）。只在 Android 上编译：
/// 宿主机没有 JVM，也没必要为它拉 `jni` 依赖。
#[cfg(target_os = "android")]
pub mod native;

pub mod playback_bridge;

pub mod player;
