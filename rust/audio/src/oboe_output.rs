//! Android 输出实现：Oboe（内部按系统版本自动选 AAudio / OpenSL ES）。
//!
//! 关键取舍：
//! - **打开时要求 Oboe 做采样率转换**（`SampleRateConversionQuality::Medium`）。
//!   44.1 kHz 的音源碰上 48 kHz 的硬件时，如果不转换就会变调，这是最容易被忽略的坑。
//! - 声道只支持 1（单声道）与 2（立体声）：这两种覆盖了音乐库的绝大多数文件，
//!   更多声道的源在引擎里已经被降混成 2。
//! - 音频回调里只做 `pop_slice` + 帧数累加，绝不加锁、绝不分配内存。

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use oboe::{
    AudioOutputCallback, AudioOutputStream, AudioOutputStreamSafe, AudioStream, AudioStreamAsync,
    AudioStreamBuilder, DataCallbackResult, Mono, Output, PerformanceMode,
    SampleRateConversionQuality, SharingMode, Status, Stereo,
};
use ringbuf::traits::Consumer;
use ringbuf::HeapCons;

use crate::error::{AudioError, Result};
use crate::output::{AudioOutput, OutputSpec};

/// 回调里绝不分配内存，所以交错缓冲按「回调最大帧数」预分配；
/// 万一系统要的帧数超过上限，多出来的部分补静音（而不是扩容）。
const MAX_CALLBACK_FRAMES: usize = 4096;

/// oboe 的 `Status` 就是 `Result<()>`，这里统一转成我们自己的错误类型。
fn check(status: Status, action: &str) -> Result<()> {
    status.map_err(|err| AudioError::Device(format!("{action} 失败：{err:?}")))
}

/// 立体声源的拉取器（音频线程持有）。
struct StereoFrames {
    consumer: HeapCons<f32>,
    played: Arc<AtomicU64>,
    /// 预分配的交错缓冲（2 × [`MAX_CALLBACK_FRAMES`] 个采样）。
    scratch: Vec<f32>,
}

impl StereoFrames {
    fn new(consumer: HeapCons<f32>, played: Arc<AtomicU64>) -> Self {
        Self {
            consumer,
            played,
            scratch: vec![0.0; MAX_CALLBACK_FRAMES * 2],
        }
    }
}

impl AudioOutputCallback for StereoFrames {
    /// 注意：立体声的帧类型是 `(f32, f32)`，回调拿到的是「帧的切片」而不是扁平采样。
    type FrameType = (f32, Stereo);

    fn on_audio_ready(
        &mut self,
        _stream: &mut dyn AudioOutputStreamSafe,
        frames: &mut [(f32, f32)],
    ) -> DataCallbackResult {
        let want = frames.len().min(MAX_CALLBACK_FRAMES) * 2;
        let got = self.consumer.pop_slice(&mut self.scratch[..want]);

        for (index, frame) in frames.iter_mut().enumerate() {
            let base = index * 2;
            // 缓冲见底（刚开流 / 暂停恢复 / 解码跟不上）时补静音：
            // 留着旧数据会变成刺耳的噪声。
            *frame = if base + 1 < got {
                (self.scratch[base], self.scratch[base + 1])
            } else {
                (0.0, 0.0)
            };
        }

        self.played.fetch_add((got / 2) as u64, Ordering::Relaxed);
        DataCallbackResult::Continue
    }
}

/// 单声道源的拉取器。
struct MonoFrames {
    consumer: HeapCons<f32>,
    played: Arc<AtomicU64>,
}

impl AudioOutputCallback for MonoFrames {
    type FrameType = (f32, Mono);

    fn on_audio_ready(
        &mut self,
        _stream: &mut dyn AudioOutputStreamSafe,
        frames: &mut [f32],
    ) -> DataCallbackResult {
        let got = self.consumer.pop_slice(frames);
        if got < frames.len() {
            frames[got..].fill(0.0);
        }
        self.played.fetch_add(got as u64, Ordering::Relaxed);
        DataCallbackResult::Continue
    }
}

/// 持有中的流。
enum Stream {
    Mono(AudioStreamAsync<Output, MonoFrames>),
    Stereo(AudioStreamAsync<Output, StereoFrames>),
}

impl Stream {
    fn start(&mut self) -> Result<()> {
        match self {
            Stream::Mono(stream) => check(stream.start(), "启动音频流"),
            Stream::Stereo(stream) => check(stream.start(), "启动音频流"),
        }
    }

    fn pause(&mut self) -> Result<()> {
        match self {
            Stream::Mono(stream) => check(stream.pause(), "暂停音频流"),
            Stream::Stereo(stream) => check(stream.pause(), "暂停音频流"),
        }
    }

    /// 关流并释放设备；丢弃错误（关闭失败也无能为力）。
    fn shutdown(&mut self) {
        match self {
            Stream::Mono(stream) => {
                let _ = stream.stop();
                let _ = stream.close();
            }
            Stream::Stereo(stream) => {
                let _ = stream.stop();
                let _ = stream.close();
            }
        }
    }
}

/// Oboe 输出设备。
pub struct OboeOutput {
    stream: Option<Stream>,
    played: Arc<AtomicU64>,
}

impl Default for OboeOutput {
    fn default() -> Self {
        Self::new()
    }
}

impl OboeOutput {
    pub fn new() -> Self {
        Self {
            stream: None,
            played: Arc::new(AtomicU64::new(0)),
        }
    }
}

impl AudioOutput for OboeOutput {
    fn start(&mut self, spec: OutputSpec, consumer: HeapCons<f32>) -> Result<()> {
        self.stop();
        // 新的一次播放从 0 开始计数。
        self.played.store(0, Ordering::Relaxed);

        let builder = AudioStreamBuilder::default()
            .set_performance_mode(PerformanceMode::LowLatency)
            .set_sharing_mode(SharingMode::Shared)
            .set_format::<f32>()
            .set_sample_rate(spec.sample_rate as i32)
            .set_sample_rate_conversion_quality(SampleRateConversionQuality::Medium);

        self.stream = Some(if spec.channels <= 1 {
            let callback = MonoFrames {
                consumer,
                played: Arc::clone(&self.played),
            };
            let stream = builder
                .set_channel_count::<Mono>()
                .set_callback(callback)
                .open_stream()
                .map_err(|err| AudioError::Device(format!("打开单声道音频流失败：{err:?}")))?
                .into();
            Stream::Mono(stream)
        } else {
            let callback = StereoFrames::new(consumer, Arc::clone(&self.played));
            let stream = builder
                .set_channel_count::<Stereo>()
                .set_callback(callback)
                .open_stream()
                .map_err(|err| AudioError::Device(format!("打开立体声音频流失败：{err:?}")))?
                .into();
            Stream::Stereo(stream)
        });

        match self.stream.as_mut() {
            Some(stream) => stream.start(),
            None => Err(AudioError::Device("音频流未建立".to_string())),
        }
    }

    fn pause(&mut self) -> Result<()> {
        match self.stream.as_mut() {
            Some(stream) => stream.pause(),
            None => Ok(()),
        }
    }

    fn resume(&mut self) -> Result<()> {
        match self.stream.as_mut() {
            Some(stream) => stream.start(),
            None => Ok(()),
        }
    }

    fn stop(&mut self) {
        if let Some(mut stream) = self.stream.take() {
            stream.shutdown();
        }
    }

    fn played_frames(&self) -> Arc<AtomicU64> {
        Arc::clone(&self.played)
    }

    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }
}
