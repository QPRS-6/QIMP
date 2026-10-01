//! 单个音频文件 → 交错 f32 采样流。
//!
//! 为什么开流时就把「第一个包」解出来：采样率/声道数在个别容器里只有解出第一帧才
//! 能确定，而输出设备必须在开流前就知道这两个值，所以干脆在这里一次定死。

use std::fs::File;
use std::path::Path;
use std::sync::OnceLock;

use symphonia::core::audio::sample::Sample;
use symphonia::core::codecs::audio::AudioDecoder as SymphoniaDecoder;
use symphonia::core::codecs::audio::AudioDecoderOptions;
use symphonia::core::codecs::registry::CodecRegistry;
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::probe::Hint;
use symphonia::core::formats::{FormatOptions, FormatReader, SeekMode, SeekTo, TrackType};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::units::{Time, TimeBase};

use crate::error::{AudioError, Result};

/// 解码器注册表：symphonia 默认那一套 + libopus。
///
/// 为什么不能直接用 `symphonia::default::get_codecs()`：symphonia 0.6 本体**没有**
/// Opus 解码器（特性列表里根本没有 opus 这一项），而 Ogg 容器里最常见的恰恰是 Opus ——
/// 手机上录的音、从网上下载的 `.ogg` 基本都是它。只带 vorbis 时这些文件会以
/// 「不支持的音频格式（无法解码）」直接播不了，真机上就是这么踩到的。
///
/// 容器侧不用动：`symphonia-format-ogg` 自己认得 OpusHead，会把 codec 标成 Opus，
/// 缺的只是「谁来解这些包」。
fn codec_registry() -> &'static CodecRegistry {
    static REGISTRY: OnceLock<CodecRegistry> = OnceLock::new();
    REGISTRY.get_or_init(|| {
        let mut registry = CodecRegistry::new();
        symphonia::default::register_enabled_codecs(&mut registry);
        registry.register_audio_decoder::<symphonia_adapter_libopus::OpusDecoder>();
        registry
    })
}

/// 解码输出的格式，输出设备按它开流。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DecoderInfo {
    pub sample_rate: u32,
    pub channels: u16,
}
/// 把 symphonia 的错误压成播放层自己的错误类型。
fn map_error(err: SymphoniaError) -> AudioError {
    match err {
        SymphoniaError::IoError(err) => AudioError::Io(err),
        SymphoniaError::Unsupported(reason) => AudioError::UnsupportedFormat(reason.to_string()),
        other => AudioError::Decode(other.to_string()),
    }
}

/// 一个正在解码的文件。
pub struct AudioDecoder {
    format: Box<dyn FormatReader>,
    decoder: Box<dyn SymphoniaDecoder>,
    track_id: u32,
    /// 容器时间基：把 seek 回报的时间戳换算回毫秒要用它（容器可能不给）。
    time_base: Option<TimeBase>,
    info: DecoderInfo,
    /// 交错采样缓冲：跨包复用，播放路径上不要反复分配内存。
    scratch: Vec<f32>,
    /// 已交给调用方的交错采样数，用于换算播放位置。
    interleaved_out: u64,
    /// `scratch` 里是否已经有一个尚未交出的包（open 时预先解出的那一包）。
    scratch_ready: bool,
}

impl std::fmt::Debug for AudioDecoder {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AudioDecoder")
            .field("info", &self.info)
            .field("interleaved_out", &self.interleaved_out)
            .finish_non_exhaustive()
    }
}

impl AudioDecoder {
    /// 打开文件并解出第一包，从而确定采样率与声道数。
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();
        let file = File::open(path)?;

        // 扩展名只是给探测器的提示，真正判定仍由内容决定。
        let mut hint = Hint::new();
        if let Some(ext) = path.extension().and_then(|ext| ext.to_str()) {
            hint.with_extension(ext);
        }

        let mss = MediaSourceStream::new(Box::new(file), Default::default());
        let format = symphonia::default::get_probe()
            .probe(
                &hint,
                mss,
                FormatOptions::default(),
                MetadataOptions::default(),
            )
            .map_err(map_error)?;

        // 这一小段全都借用 `format`（track / params 都指向它）。先把要用的值取出来，
        // 借用结束后才能把 `format` 移进结构体。
        let (track_id, time_base, decoder, fallback_info) = {
            let track = format
                .default_track(TrackType::Audio)
                .ok_or_else(|| AudioError::NoAudioTrack(path.display().to_string()))?;
            let params = track
                .codec_params
                .as_ref()
                .and_then(|params| params.audio())
                .ok_or_else(|| AudioError::UnsupportedFormat("缺少编解码参数".to_string()))?;

            let decoder = codec_registry()
                .make_audio_decoder(params, &AudioDecoderOptions::default())
                .map_err(map_error)?;

            let info = DecoderInfo {
                sample_rate: params.sample_rate.unwrap_or(0),
                channels: params
                    .channels
                    .as_ref()
                    .map(|channels| channels.count() as u16)
                    .unwrap_or(0),
            };
            (track.id, track.time_base, decoder, info)
        };

        let mut this = Self {
            format,
            decoder,
            track_id,
            time_base,
            // 先用容器声明的信息兜底；下面解出第一包后会以实际格式覆盖。
            info: fallback_info,
            scratch: Vec::new(),
            interleaved_out: 0,
            scratch_ready: false,
        };

        if !this.decode_next_packet()? {
            return Err(AudioError::UnsupportedFormat(
                "文件里没有可播放的音频数据".to_string(),
            ));
        }
        this.scratch_ready = true;
        Ok(this)
    }

    pub fn info(&self) -> DecoderInfo {
        self.info
    }

    /// 已解出的时长（毫秒），按“已交给输出设备的采样数”换算。
    pub fn position_ms(&self) -> u64 {
        if self.info.sample_rate == 0 || self.info.channels == 0 {
            return 0;
        }
        let frames = self.interleaved_out / u64::from(self.info.channels);
        frames * 1000 / u64::from(self.info.sample_rate)
    }

    /// 取下一批交错 f32 采样；`None` 表示文件结束。
    ///
    /// 返回的切片在下一次调用前有效（复用同一块缓冲），调用方必须立刻拷走。
    pub fn next_chunk(&mut self) -> Result<Option<&[f32]>> {
        // open 时预解的那一包：第一次调用直接交出去。
        if self.scratch_ready {
            self.scratch_ready = false;
        } else if !self.decode_next_packet()? {
            return Ok(None);
        }
        self.interleaved_out += self.scratch.len() as u64;
        Ok(Some(&self.scratch))
    }

    /// 跳到指定位置（毫秒），返回跳转后**实际**到达的位置（毫秒）。
    pub fn seek(&mut self, position_ms: u64) -> Result<u64> {
        let seeked = self
            .format
            .seek(
                SeekMode::Accurate,
                SeekTo::Time {
                    time: Time::from_millis(position_ms as i64),
                    track_id: Some(self.track_id),
                },
            )
            .map_err(map_error)?;

        // 换位置后解码器内部的预测状态不再有效，必须重置。
        self.decoder.reset();

        // 用容器回报的时间戳修正位置：请求 30s 时可能落在 29.98s，
        // 不修正的话进度条会先跳回去再往前走。容器没给时间基时退回请求值。
        let actual_ms = match self.time_base.and_then(|tb| tb.calc_time(seeked.actual_ts)) {
            Some(time) => time.as_millis().max(0) as u64,
            None => position_ms,
        };
        let frames = actual_ms * u64::from(self.info.sample_rate) / 1000;
        self.interleaved_out = frames * u64::from(self.info.channels);
        self.scratch.clear();
        self.scratch_ready = false;
        Ok(actual_ms)
    }

    /// 解下一包到 `scratch`；返回是否真的解到了数据。
    fn decode_next_packet(&mut self) -> Result<bool> {
        loop {
            let packet = match self.format.next_packet() {
                Ok(Some(packet)) => packet,
                Ok(None) => return Ok(false),
                // 只有链式 Ogg 会出现，按“本文件播完”处理即可。
                Err(SymphoniaError::ResetRequired) => return Ok(false),
                Err(err) => return Err(map_error(err)),
            };

            if packet.track_id != self.track_id {
                continue;
            }

            match self.decoder.decode(&packet) {
                Ok(buffer) => {
                    // 以实际解出的格式为准（个别容器要解出第一帧才知道采样率）。
                    let spec = buffer.spec();
                    self.info = DecoderInfo {
                        sample_rate: spec.rate(),
                        channels: spec.channels().count() as u16,
                    };
                    self.scratch.resize(buffer.samples_interleaved(), f32::MID);
                    buffer.copy_to_slice_interleaved(&mut self.scratch);
                    return Ok(true);
                }
                // 单个坏包不该中断整首歌：跳过它继续解下一包。
                Err(SymphoniaError::DecodeError(_)) | Err(SymphoniaError::IoError(_)) => continue,
                Err(err) => return Err(map_error(err)),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{write_wav, WAV_CHANNELS, WAV_RATE};

    /// 解完整首：帧数应等于“采样率 × 秒数”，位置也应走到结尾。
    #[test]
    fn decodes_full_wav_with_expected_frame_count() {
        let temp = tempfile::tempdir().expect("临时目录");
        let path = temp.path().join("one-second.wav");
        write_wav(&path, 1);

        let mut decoder = AudioDecoder::open(&path).expect("打开 WAV");
        let info = decoder.info();
        assert_eq!(info.sample_rate, WAV_RATE);
        assert_eq!(info.channels, WAV_CHANNELS);

        let mut frames = 0usize;
        while let Some(chunk) = decoder.next_chunk().expect("解码") {
            assert_eq!(
                chunk.len() % usize::from(WAV_CHANNELS),
                0,
                "交错缓冲必须按整帧对齐"
            );
            frames += chunk.len() / usize::from(WAV_CHANNELS);
        }
        assert_eq!(frames, WAV_RATE as usize, "1 秒 8kHz 应正好 8000 帧");
        assert!(
            (990..=1010).contains(&decoder.position_ms()),
            "位置应接近 1000ms，实际 {}",
            decoder.position_ms()
        );
    }

    /// 跳转：请求 500ms，实际落点也应接近 500ms，且之后还能继续解码。
    #[test]
    fn seek_lands_near_requested_position_and_keeps_decoding() {
        let temp = tempfile::tempdir().expect("临时目录");
        let path = temp.path().join("two-seconds.wav");
        write_wav(&path, 2);

        let mut decoder = AudioDecoder::open(&path).expect("打开 WAV");
        let actual = decoder.seek(500).expect("跳转");
        // symphonia 的 `Accurate` 语义是「跳到不晚于目标的位置」：容器只能落在包边界上，
        // 所以落点会略早于目标而不是精确相等。WAV 的包较大，这里放宽到 100ms。
        assert!(
            (400..=500).contains(&actual),
            "实际落点应不晚于 500ms 且足够接近，实际 {actual}"
        );
        let after_seek = decoder.position_ms();
        assert!(
            (400..=500).contains(&after_seek),
            "跳转后的位置应与落点一致，实际 {after_seek}"
        );

        let chunk = decoder.next_chunk().expect("解码").expect("还有数据");
        assert!(!chunk.is_empty(), "跳转后应还能继续解码");
        assert!(
            decoder.position_ms() > after_seek,
            "继续解码后位置应向前推进：{} -> {}",
            after_seek,
            decoder.position_ms()
        );
    }

    /// 打不开的文件要给可读错误，而不是 panic 或静默成功。
    #[test]
    fn opening_garbage_reports_error() {
        let temp = tempfile::tempdir().expect("临时目录");
        let path = temp.path().join("not-audio.mp3");
        std::fs::write(&path, b"this is definitely not audio").expect("写入垃圾数据");

        match AudioDecoder::open(&path) {
            Ok(_) => panic!("垃圾数据不应被当成音频"),
            Err(err) => {
                let message = err.to_string();
                assert!(!message.is_empty(), "错误信息不该是空的");
            }
        }
    }
}
