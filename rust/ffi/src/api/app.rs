//! 应用级接口：启动自检 + 基础信息。
//!
//! 书写约定：
//! - 默认生成**异步**接口（Dart 侧拿到 `Future`）；确实是纯计算的短函数才加 `#[frb(sync)]`。
//! - 只使用 FRB 可翻译的类型（`String` / `i64` / `bool` / `Vec<T>` / 自定义 struct）。

use flutter_rust_bridge::frb;

/// 由生成的 `RustLib.init()` 调用一次，装载默认工具（日志、panic 转 Dart 异常等）。
#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

/// 核心库版本号。Dart 侧调用它即可确认 FFI 通道已经打通。
#[frb(sync)]
pub fn core_version() -> String {
    musicplayer_core::CORE_VERSION.to_owned()
}

/// 默认纳入曲库的音频扩展名（小写、不含点号），供 Dart 侧做兜底过滤。
#[frb(sync)]
pub fn default_audio_extensions() -> Vec<String> {
    musicplayer_core::default_audio_extensions()
}

#[cfg(test)]
mod tests {
    /// 扩展名清单是对 UI 的契约：必须非空且全部小写、不含点号。
    #[test]
    fn extensions_are_lowercase_without_dot() {
        let exts = super::default_audio_extensions();
        assert!(!exts.is_empty());
        for ext in &exts {
            assert_eq!(ext, &ext.to_lowercase(), "扩展名必须小写: {ext}");
            assert!(!ext.starts_with('.'), "扩展名不应带点号: {ext}");
        }
    }

    #[test]
    fn version_is_reported() {
        assert_eq!(super::core_version(), musicplayer_core::CORE_VERSION);
    }
}
