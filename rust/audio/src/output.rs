//! 音频输出抽象：把「往哪里写采样」从播放引擎里剥出来。
//!
//! 直接好处：引擎 / 解码 / 队列都能在宿主机上完整测试（用 [`NullOutput`] 手动泵采样），
//! Android 专属的 Oboe 代码只集中在 `output::oboe_output` 一个文件里。
//!
//! 线程约定：`start` 给出的 `consumer` 归**音频线程**独占；音频回调里禁止加锁、
//! 禁止分配内存，所以数据通路用的是无锁环形缓冲。

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use ringbuf::traits::{Consumer, Observer, Split};
use ringbuf::{HeapCons, HeapProd, HeapRb};

use crate::error::Result;

/// 输出设备的共享句柄：播放线程用它开流/暂停，FFI 侧的测试用它手动泵采样。
pub type AudioOutputHandle = Arc<Mutex<Box<dyn AudioOutput>>>;

/// 把具体输出设备包装成共享句柄。
pub fn shared_output(output: Box<dyn AudioOutput>) -> AudioOutputHandle {
    Arc::new(Mutex::new(output))
}

/// 输出格式：开流前必须确定。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OutputSpec {
    pub sample_rate: u32,
    pub channels: u16,
}

impl OutputSpec {
    /// 交错缓冲里一帧的采样数。
    pub fn samples_per_frame(&self) -> usize {
        usize::from(self.channels.max(1))
    }
}

/// 音频输出设备。
pub trait AudioOutput: Send {
    /// 以给定格式启动（若已有流则先关掉）。`consumer` 交给音频线程。
    fn start(&mut self, spec: OutputSpec, consumer: HeapCons<f32>) -> Result<()>;

    /// 暂停（保留流，恢复更快）。
    fn pause(&mut self) -> Result<()>;

    /// 从暂停恢复。
    fn resume(&mut self) -> Result<()>;

    /// 关闭流并释放设备。
    fn stop(&mut self);

    /// 已播出帧数的共享计数器：音频线程累加，引擎只读（不加锁）。
    fn played_frames(&self) -> Arc<AtomicU64>;

    /// 向下转型入口：测试要对手动泵采样的实现做具体类型操作，
    /// 生产代码也可用它查询设备能力（例如判断当前是不是真实设备）。
    fn as_any_mut(&mut self) -> &mut dyn std::any::Any;
}

/// 环形缓冲容量：约 250 ms。
///
/// 太小会在主线程偶发卡顿时断音，太大则暂停/跳转的响应变迟钝。
fn ring_capacity(spec: OutputSpec) -> usize {
    let frames = (spec.sample_rate / 4).max(1024) as usize;
    frames * spec.samples_per_frame()
}

/// 建一个环形缓冲，返回「写入端」与「消费端」。
pub fn ring_buffer(spec: OutputSpec) -> (HeapProd<f32>, HeapCons<f32>) {
    HeapRb::<f32>::new(ring_capacity(spec)).split()
}

/// 不出声的输出：不接任何设备，采样由调用方手动“取走”。
///
/// 用途是测试（`pump` 让播放进度完全可控）与“无音频设备”时的兜底。
pub struct NullOutput {
    consumer: Option<HeapCons<f32>>,
    samples_per_frame: usize,
    played: Arc<AtomicU64>,
    spec: Option<OutputSpec>,
    /// 暂停时不再取走采样——真实设备在暂停时同样不会回调音频线程。
    paused: bool,
}

impl Default for NullOutput {
    fn default() -> Self {
        Self::new()
    }
}

impl NullOutput {
    pub fn new() -> Self {
        Self {
            consumer: None,
            samples_per_frame: 1,
            played: Arc::new(AtomicU64::new(0)),
            spec: None,
            paused: false,
        }
    }

    pub fn spec(&self) -> Option<OutputSpec> {
        self.spec
    }

    /// 是否处于暂停（暂停期间 [`Self::pump`] 不取走任何采样）。
    pub fn is_paused(&self) -> bool {
        self.paused
    }

    /// 模拟音频线程取走 `frames` 帧；返回真正取到的采样数（队列里不够就少于请求）。
    pub fn pump(&mut self, frames: usize) -> usize {
        if self.paused {
            return 0;
        }
        let Some(consumer) = self.consumer.as_mut() else {
            return 0;
        };
        let want = frames * self.samples_per_frame;
        let mut scratch = vec![0.0f32; want];
        let got = consumer.pop_slice(&mut scratch);
        let got_frames = (got / self.samples_per_frame) as u64;
        self.played.fetch_add(got_frames, Ordering::Relaxed);
        got
    }

    /// 还排在队列里、尚未被取走的采样数（测试用来判断“已经灌满”）。
    pub fn buffered(&self) -> usize {
        self.consumer
            .as_ref()
            .map(|c| c.occupied_len())
            .unwrap_or(0)
    }
}

impl AudioOutput for NullOutput {
    fn start(&mut self, spec: OutputSpec, consumer: HeapCons<f32>) -> Result<()> {
        self.consumer = Some(consumer);
        self.samples_per_frame = spec.samples_per_frame();
        self.spec = Some(spec);
        self.paused = false;
        // 与真实设备一致：新的一次播放从 0 开始计帧。
        self.played.store(0, Ordering::Relaxed);
        Ok(())
    }

    fn pause(&mut self) -> Result<()> {
        self.paused = true;
        Ok(())
    }

    fn resume(&mut self) -> Result<()> {
        self.paused = false;
        Ok(())
    }

    fn stop(&mut self) {
        self.consumer = None;
        self.spec = None;
        self.paused = false;
    }

    fn played_frames(&self) -> Arc<AtomicU64> {
        Arc::clone(&self.played)
    }

    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }
}

#[cfg(test)]
mod tests {
    use ringbuf::traits::Producer;

    use super::*;

    #[test]
    fn ring_capacity_scales_with_channels() {
        let mono = OutputSpec {
            sample_rate: 8_000,
            channels: 1,
        };
        let stereo = OutputSpec {
            sample_rate: 8_000,
            channels: 2,
        };
        assert_eq!(ring_capacity(stereo), ring_capacity(mono) * 2);
    }

    #[test]
    fn null_output_counts_frames_not_samples() {
        let spec = OutputSpec {
            sample_rate: 48_000,
            channels: 2,
        };
        let (mut producer, consumer) = ring_buffer(spec);
        let mut out = NullOutput::new();
        out.start(spec, consumer).expect("开流");

        // 写入 100 帧（200 个采样）
        let chunk = vec![0.5f32; 200];
        assert_eq!(producer.push_slice(&chunk), 200);

        assert_eq!(out.pump(100), 200);
        assert_eq!(out.played_frames().load(Ordering::Relaxed), 100);
    }

    #[test]
    fn null_output_stops_consuming_after_stop() {
        let spec = OutputSpec {
            sample_rate: 8_000,
            channels: 1,
        };
        let (mut producer, consumer) = ring_buffer(spec);
        let mut out = NullOutput::new();
        out.start(spec, consumer).expect("开流");
        producer.push_slice(&[0.0; 10]);

        out.stop();
        assert_eq!(out.pump(10), 0, "关流后不应再取走采样");
    }
}
