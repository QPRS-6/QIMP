use serde::{Deserialize, Serialize};

pub type TrackId = i64;
pub type PlaylistId = i64;

/// 单曲的完整信息：既有磁盘上的实时信息，也有从元数据/数据库读出的信息。
///
/// `id == 0` 表示这条记录还没有入库（例如刚被 `metadata::read` 读出来）。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Track {
    pub id: TrackId,
    /// 绝对路径。Android 上是 SAF 授权目录映射后的真实路径。
    pub path: String,
    pub title: String,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub album_artist: Option<String>,
    pub genre: Option<String>,
    pub year: Option<u32>,
    pub track_no: Option<u32>,
    pub disc_no: Option<u32>,
    /// 时长（毫秒）。0 表示未知，UI 需要显示 `--:--`。
    pub duration_ms: u64,
    pub bitrate: Option<u32>,
    pub sample_rate: Option<u32>,
    pub channels: Option<u8>,
    pub size_bytes: u64,
    /// 文件 mtime（Unix 秒），增量扫描靠它判断是否需要重新读元数据。
    pub modified_at: i64,
    pub has_cover: bool,
    /// 入库时间（Unix 秒），用于“最近添加”排序。
    pub added_at: i64,
}

impl Track {
    /// 显示名：优先标题，空标题回退到文件名。
    pub fn display_title(&self) -> &str {
        if self.title.trim().is_empty() {
            self.path.rsplit('/').next().unwrap_or(&self.path)
        } else {
            &self.title
        }
    }

    /// 供 UI 分组的“专辑归属键”：专辑名 + 专辑艺术家。
    pub fn album_key(&self) -> Option<(String, String)> {
        let album = self.album.as_ref()?.trim();
        if album.is_empty() {
            return None;
        }
        let artist = self
            .album_artist
            .as_deref()
            .or(self.artist.as_deref())
            .unwrap_or("未知艺术家")
            .trim();
        Some((album.to_string(), artist.to_string()))
    }

    pub fn is_persisted(&self) -> bool {
        self.id > 0
    }
}

/// 专辑聚合信息（由数据库 GROUP BY 得到）。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Album {
    pub name: String,
    pub album_artist: String,
    pub track_count: u32,
    pub duration_ms: u64,
    pub year: Option<u32>,
    pub has_cover: bool,
}

/// 艺术家聚合信息。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Artist {
    pub name: String,
    pub track_count: u32,
    pub album_count: u32,
}

/// 播放列表。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Playlist {
    pub id: PlaylistId,
    pub name: String,
    pub track_count: u32,
    pub created_at: i64,
}

/// 单曲播放进度，用于“继续播放”和“最近播放”。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlayState {
    pub track_id: TrackId,
    pub position_ms: u64,
    pub play_count: u32,
    pub last_played_at: i64,
}

/// 库整体统计。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Stats {
    pub track_count: u32,
    pub album_count: u32,
    pub artist_count: u32,
    pub playlist_count: u32,
    pub total_duration_ms: u64,
    pub total_size_bytes: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SortKey {
    Title,
    Artist,
    Album,
    AddedAt,
    Duration,
    Path,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SortOrder {
    Ascending,
    Descending,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum MediaKind {
    Audio,
    Video,
}

/// 扫描模式。增量扫描只读取 mtime/size 变化的文件，是启动时的默认选项。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ScanMode {
    Full,
    Incremental,
}

/// 扫描进度，通过回调推送给 UI（后续经 FRB 以 Stream 形式暴露）。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScanProgress {
    pub scanned: u32,
    pub total: u32,
    pub current_path: String,
}

/// 扫描结果汇总。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScanSummary {
    pub added: u32,
    pub updated: u32,
    pub removed: u32,
    pub skipped: u32,
    pub failed: u32,
    pub elapsed_ms: u64,
    /// 失败明细，UI 可折叠展示。
    pub errors: Vec<String>,
}

impl ScanSummary {
    pub fn touched(&self) -> u32 {
        self.added + self.updated + self.removed
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_title_falls_back_to_file_name() {
        let mut t = Track {
            path: "/m/a/b/song.mp3".into(),
            ..Default::default()
        };
        assert_eq!(t.display_title(), "song.mp3");
        t.title = "  ".into();
        assert_eq!(t.display_title(), "song.mp3");
        t.title = "Real Title".into();
        assert_eq!(t.display_title(), "Real Title");
    }

    #[test]
    fn album_key_requires_album_and_defaults_artist() {
        let mut t = Track::default();
        assert_eq!(t.album_key(), None);

        t.album = Some("  ".into());
        assert_eq!(t.album_key(), None);

        t.album = Some("Kind of Blue".into());
        assert_eq!(
            t.album_key(),
            Some(("Kind of Blue".to_string(), "未知艺术家".to_string()))
        );

        t.artist = Some("Miles Davis".into());
        assert_eq!(
            t.album_key(),
            Some(("Kind of Blue".to_string(), "Miles Davis".to_string()))
        );

        t.album_artist = Some("Miles Davis Quintet".into());
        assert_eq!(
            t.album_key(),
            Some((
                "Kind of Blue".to_string(),
                "Miles Davis Quintet".to_string()
            ))
        );
    }

    #[test]
    fn is_persisted_uses_positive_id() {
        assert!(!Track::default().is_persisted());
        let t = Track {
            id: 7,
            ..Default::default()
        };
        assert!(t.is_persisted());
    }
}
