//! Android 输出实现：Oboe（内部按系统版本自动选 AAudio / OpenSL ES）。
//!
//! 关键取舍：
//! - **打开时要求 Oboe 做采样率转换**（`SampleRateConversionQuality::Medium`）。
//!   44.1 kHz 的音源碰上 48 kHz 的硬件时，如果不转换就会变调，这是最容易被忽略的坑。
//! - 声道只支持 1（单声道）与 2（立体声）：这两种覆盖了音乐库的绝大多数文件，
//!   更多声道的源在引擎里已经被降混成 2。
//! - 音频回调里只做 `pop_slice` + 帧数累加，绝不加锁、绝不分配内存。

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;

use oboe::{
    AudioOutputCallback, AudioOutputStream, AudioOutputStreamSafe, AudioStream, AudioStreamAsync,
    AudioStreamBuilder, DataCallbackResult, Error, Mono, Output, PerformanceMode,
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
    /// 「系统把这条流关了」的标记，与 [`OboeOutput`] 共享（见 [`AudioOutput::needs_reopen`]）。
    needs_reopen: Arc<AtomicBool>,
    /// 预分配的交错缓冲（2 × [`MAX_CALLBACK_FRAMES`] 个采样）。
    scratch: Vec<f32>,
}

impl StereoFrames {
    fn new(consumer: HeapCons<f32>, played: Arc<AtomicU64>, needs_reopen: Arc<AtomicBool>) -> Self {
        Self {
            consumer,
            played,
            needs_reopen,
            scratch: vec![0.0; MAX_CALLBACK_FRAMES * 2],
        }
    }
}

impl AudioOutputCallback for StereoFrames {
    /// 注意：立体声的帧类型是 `(f32, f32)`，回调拿到的是「帧的切片」而不是扁平采样。
    type FrameType = (f32, Stereo);

    /// 系统把这条流关了：换输出设备（蓝牙连上 / 断开、拔耳机）时 AAudio 就会这么做。
    ///
    /// 这时底层流已经被 Oboe 关掉，再 `start` / `pause` 只会一直报错；Oboe 的文档说得很
    /// 明白——这个回调就是留给「在另一台设备上重开一条流」用的。但我们手上只有消费端、
    /// 不知道播到哪儿了，重开得由引擎来做，所以这里只落一个标记。
    ///
    /// 回调里不能加锁、不能分配内存，一个原子写正合适。
    fn on_error_after_close(&mut self, _stream: &mut dyn AudioOutputStreamSafe, _error: Error) {
        self.needs_reopen.store(true, Ordering::Relaxed);
    }

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
    /// 同 [`StereoFrames::needs_reopen`]。
    needs_reopen: Arc<AtomicBool>,
}

impl AudioOutputCallback for MonoFrames {
    type FrameType = (f32, Mono);

    /// 同 [`StereoFrames`]：系统关掉这条流时留个标记，重开的事交给引擎。
    fn on_error_after_close(&mut self, _stream: &mut dyn AudioOutputStreamSafe, _error: Error) {
        self.needs_reopen.store(true, Ordering::Relaxed);
    }

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
    /// 「系统把这条流关了」的标记，与**当前这一条**流的回调共享
    /// （见 [`AudioOutput::needs_reopen`]）。
    ///
    /// 每条流配一个新的 `Arc`：上一条流的错误回调晚一点才到也没关系，它写的是没人再看的
    /// 旧标记，不会把刚开好的新流误判成「又没用了」。
    needs_reopen: Arc<AtomicBool>,
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
            needs_reopen: Arc::new(AtomicBool::new(false)),
        }
    }
}

impl AudioOutput for OboeOutput {
    fn start(&mut self, spec: OutputSpec, consumer: HeapCons<f32>) -> Result<()> {
        self.stop();
        // 新的一次播放从 0 开始计数。
        self.played.store(0, Ordering::Relaxed);
        // 新流配新标记，见字段说明。
        self.needs_reopen = Arc::new(AtomicBool::new(false));
        let needs_reopen = Arc::clone(&self.needs_reopen);

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
                needs_reopen,
            };
            let stream = builder
                .set_channel_count::<Mono>()
                .set_callback(callback)
                .open_stream()
                .map_err(|err| AudioError::Device(format!("打开单声道音频流失败：{err:?}")))?;
            Stream::Mono(stream)
        } else {
            let callback = StereoFrames::new(consumer, Arc::clone(&self.played), needs_reopen);
            let stream = builder
                .set_channel_count::<Stereo>()
                .set_callback(callback)
                .open_stream()
                .map_err(|err| AudioError::Device(format!("打开立体声音频流失败：{err:?}")))?;
            Stream::Stereo(stream)
        });

        match self.stream.as_mut() {
            Some(stream) => stream.start(),
            None => Err(AudioError::Device("音频流未建立".to_string())),
        }
    }

    fn pause(&mut self) -> Result<()> {
        // 流已经被系统关掉（换输出设备）：它本来就不出声，「暂停成功」是实话。
        // 蓝牙断开时平台侧会自动暂停，这条路上冒一个「暂停失败」只会吓人。
        if self.needs_reopen.load(Ordering::Relaxed) {
            return Ok(());
        }
        match self.stream.as_mut() {
            Some(stream) => stream.pause(),
            None => Ok(()),
        }
    }

    fn resume(&mut self) -> Result<()> {
        // 关掉的流再也不会启动（Oboe 那边给的是 `ErrorClosed`）：把错误报出去，
        // 引擎会按当前位置重开一条（见 [`AudioOutput::needs_reopen`]）。
        if self.needs_reopen.load(Ordering::Relaxed) {
            return Err(AudioError::Device("音频输出设备已切换".to_string()));
        }
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

    fn needs_reopen(&self) -> bool {
        self.needs_reopen.load(Ordering::Relaxed)
    }

    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }
}
