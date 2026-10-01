//! 播放层：解码（symphonia）+ 播放队列 + 播放引擎。
//!
//! 设计要点：
//! - **核心逻辑与平台无关**：解码、队列、进度换算都能在宿主机上单测，
//!   平台相关的只有“往哪写 PCM 采样”，因此抽象成 [`output::AudioOutput`]。
//! - Android 上的实际输出由 [`output::oboe`] 提供（Oboe/AAudio），
//!   宿主机与测试用[`output::null`]（丢弃采样，只推进时间轴）。

pub mod decoder;
pub mod engine;
pub mod error;
pub mod output;
pub mod queue;

/// 测试夹具（生成真实 WAV），只在测试构建里编译。
#[cfg(test)]
pub mod test_support;

/// Android 专用输出实现（Oboe）。其它平台不编译它，所以能在宿主机上跑测试。
#[cfg(target_os = "android")]
pub mod oboe_output;

pub use decoder::{AudioDecoder, DecoderInfo};
pub use engine::{Engine, PlayerSnapshot, PlayerState};
pub use error::{AudioError, Result};
pub use output::{shared_output, AudioOutput, AudioOutputHandle, NullOutput, OutputSpec};
pub use queue::{PlayQueue, QueueItem, RepeatMode};

/// 平台默认输出设备：Android 用 Oboe；开发机 / 测试环境用不出声的实现。
///
/// 注意：宿主机上的 [`NullOutput`] 不会自己消耗采样，需要调用方手动 `pump`，
/// 因此它只适合测试；真机上一律走 Oboe。
pub fn platform_output() -> AudioOutputHandle {
    #[cfg(target_os = "android")]
    {
        output::shared_output(Box::new(oboe_output::OboeOutput::new()))
    }
    #[cfg(not(target_os = "android"))]
    {
        output::shared_output(Box::new(NullOutput::new()))
    }
}
