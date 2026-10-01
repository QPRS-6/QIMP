use std::path::PathBuf;

/// 核心层统一错误类型。
///
/// 注意：对外暴露给 Flutter 的错误信息只应包含用户可读的描述，
/// 不能把绝对路径泄露到 UI 层（由调用方决定是否脱敏）。
#[derive(Debug, thiserror::Error)]
pub enum CoreError {
    #[error("文件系统错误: {0}")]
    Io(#[from] std::io::Error),

    #[error("数据库错误: {0}")]
    Database(#[from] rusqlite::Error),

    #[error("无法解析音频元数据: {path} ({reason})")]
    Metadata { path: PathBuf, reason: String },

    #[error("不支持的音频格式: {0}")]
    UnsupportedFormat(PathBuf),

    #[error("数据不一致: {0}")]
    Integrity(String),
}

pub type Result<T> = std::result::Result<T, CoreError>;

impl CoreError {
    /// 便于在扫描阶段把任意错误降级为“这条文件跳过”，而不是让整次扫描失败。
    pub fn metadata(path: impl Into<PathBuf>, err: impl std::fmt::Display) -> Self {
        CoreError::Metadata {
            path: path.into(),
            reason: err.to_string(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn metadata_error_keeps_path_out_of_display_message_shape() {
        let err = CoreError::metadata("/music/a.flac", "bad header");
        assert!(err.to_string().contains("bad header"));
        assert!(err.to_string().contains("a.flac"));
    }
}
