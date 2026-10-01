//! 解码器格式覆盖面：用真实的小样本文件跑一遍（见 `rust/testdata/README.md`）。
//!
//! 重点是 **Ogg Opus**：symphonia 0.6 本体没有 Opus 解码器，靠
//! `symphonia-adapter-libopus` 补上。只带 vorbis 时它会在真机上以
//! 「不支持的音频格式（无法解码）」直接播不了，所以这里必须钉住。
use musicplayer_audio::AudioDecoder;

fn sample(name: &str) -> String {
    format!("{}/../testdata/{name}", env!("CARGO_MANIFEST_DIR"))
}

/// 解完整首，返回 (采样率, 声道, 帧数)。
fn decode_all(name: &str) -> (u32, u16, usize) {
    let path = sample(name);
    let mut decoder =
        AudioDecoder::open(&path).unwrap_or_else(|err| panic!("打开 {name} 失败：{err}"));
    let info = decoder.info();

    let mut frames = 0usize;
    while let Some(chunk) = decoder.next_chunk().expect("解码") {
        assert_eq!(
            chunk.len() % usize::from(info.channels.max(1)),
            0,
            "{name}: 交错缓冲必须按整帧对齐"
        );
        frames += chunk.len() / usize::from(info.channels.max(1));
    }
    (info.sample_rate, info.channels, frames)
}

#[test]
fn decodes_ogg_opus() {
    // Opus 一律按 48kHz 输出，与文件头声明 16kHz 的“输入采样率”无关。
    let (rate, channels, frames) = decode_all("ogg_opus.ogg");
    assert_eq!(rate, 48000, "Opus 解码输出固定 48kHz");
    assert_eq!(channels, 1);
    assert!(
        frames.abs_diff(48000) <= 4800,
        "1 秒样本解出 {frames} 帧，期望接近 48000（放宽 10%，Opus 有编解码延迟）"
    );
}

#[test]
fn decodes_ogg_vorbis() {
    let (rate, channels, frames) = decode_all("ogg_vorbis.ogg");
    assert_eq!(rate, 16000);
    assert_eq!(channels, 1);
    assert!(
        frames.abs_diff(16000) <= 1600,
        "1 秒样本解出 {frames} 帧，期望接近 16000"
    );
}
