//! 播放层错误。
//!
//! 刻意**不复用** `musicplayer_core::CoreError`：曲库层关心的是“扫描/索引”，
//! 播放层关心的是“解码/设备”，混在一起会让上层无法区分该重试还是该跳过。

/// 播放层统一错误类型。
#[derive(Debug, thiserror::Error)]
pub enum AudioError {
    #[error("文件系统错误: {0}")]
    Io(#[from] std::io::Error),

    #[error("不支持的音频格式（无法解码）: {0}")]
    UnsupportedFormat(String),

    #[error("文件里没有可播放的音频轨: {0}")]
    NoAudioTrack(String),

    #[error("解码失败: {0}")]
    Decode(String),

    /// 跳转目标超出容器声明的范围。
    ///
    /// 与「文件里实际的数据比声明时长短」（下载没下完、拷贝被掐断）是同一类问题：
    /// 用户把进度条拖到最后就会落到这儿。播放层不把它当成播放错误，而是当作
    /// 「这一首到头了」，见 `engine.rs` 的 `is_past_end`。
    #[error("跳转目标超出文件范围: {0}")]
    SeekOutOfRange(String),

    #[error("音频设备错误: {0}")]
    Device(String),

    #[error("播放队列为空")]
    EmptyQueue,
}

pub type Result<T> = std::result::Result<T, AudioError>;
