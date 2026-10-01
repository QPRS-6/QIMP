//! 测试夹具：生成**真实可解码**的音频文件。
//!
//! 播放链路的测试必须用真文件：空壳文件在探测阶段就会失败，测不到解码、时长、
//! 跳转这些真正容易出错的地方。

use std::path::Path;

/// 写一个最小但合法的 WAV：8 kHz / 单声道 / 8bit PCM，时长 `seconds` 秒。
///
/// 选 WAV 是因为它可以手工拼出来（44 字节头 + PCM 数据），不依赖任何编码器。
pub fn write_wav(path: &Path, seconds: u32) {
    const RATE: u32 = 8_000;
    let data_len = RATE * seconds;
    let mut bytes = Vec::with_capacity(44 + data_len as usize);
    bytes.extend_from_slice(b"RIFF");
    bytes.extend_from_slice(&(36 + data_len).to_le_bytes());
    bytes.extend_from_slice(b"WAVE");
    bytes.extend_from_slice(b"fmt ");
    bytes.extend_from_slice(&16u32.to_le_bytes()); // fmt 块长度
    bytes.extend_from_slice(&1u16.to_le_bytes()); // PCM
    bytes.extend_from_slice(&1u16.to_le_bytes()); // 单声道
    bytes.extend_from_slice(&RATE.to_le_bytes());
    bytes.extend_from_slice(&RATE.to_le_bytes()); // byte rate = 采样率 × 声道 × 位深字节
    bytes.extend_from_slice(&1u16.to_le_bytes()); // block align
    bytes.extend_from_slice(&8u16.to_le_bytes()); // 位深
    bytes.extend_from_slice(b"data");
    bytes.extend_from_slice(&data_len.to_le_bytes());
    // 8bit PCM 的静音电平是 0x80；顺便叠一段锯齿波，方便将来验证波形与声道。
    for index in 0..data_len {
        bytes.push(128 + (index % 32) as u8);
    }
    std::fs::write(path, bytes).expect("写入测试 WAV");
}

/// 采样率与声道数，供断言使用。
pub const WAV_RATE: u32 = 8_000;
pub const WAV_CHANNELS: u16 = 1;
