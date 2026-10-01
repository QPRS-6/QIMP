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

/// 播放列表的**文件**格式。
///
/// 只支持这两种：它们是各播放器导出、分享时最通用的两种文本格式，
/// 而且都不需要额外的依赖就能读写（见 [`crate::playlist_file`]）。
/// 二进制的 `.wpl`、带媒体库路径的 `.itunesxml` 一概不认——那些既不好解析，
/// 也不解决手机上的实际问题。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum PlaylistFileFormat {
    /// `.m3u` / `.m3u8`：一行一个路径，`#` 开头是注释与 `#EXTINF`。
    #[default]
    M3u,
    /// `.xspf`：XML，条目在 `<trackList><track><location>` 里。
    Xspf,
}

impl PlaylistFileFormat {
    /// 导出时的扩展名（不含点）。
    pub fn extension(&self) -> &'static str {
        match self {
            PlaylistFileFormat::M3u => "m3u8",
            PlaylistFileFormat::Xspf => "xspf",
        }
    }
}

/// 导入一份播放列表文件的结果。
///
/// 「对不上」的条目单独计数而不是直接报错：一份从别的机器导出的列表里总有几首
/// 本机没有的歌，为此把整次导入判为失败对用户毫无帮助。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlaylistImport {
    /// 新建的列表 id。
    pub playlist_id: PlaylistId,
    /// 真正加进列表的条数（同一首歌在文件里重复出现只算一次）。
    pub added: u32,
    /// 对不上曲库的条数（本地索引里没有这个文件，多半是从没扫到过）。
    pub missing: u32,
    /// 对不上的前几条，给界面展示用；只保留前 [`MISSING_PREVIEW_LIMIT`] 条。
    pub missing_paths: Vec<String>,
    /// 文件里是网络地址（`http://` 之类）而跳过的条数：本地播放器放不了它们。
    pub skipped: u32,
}

/// [`PlaylistImport::missing_paths`] 最多回给界面几条。
///
/// 一份列表全对不上时可能有几百条，全塞给界面只会让提示变成一堵墙。
pub const MISSING_PREVIEW_LIMIT: usize = 10;

/// 单曲播放进度，用于“继续播放”和“最近播放”。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlayState {
    pub track_id: TrackId,
    pub position_ms: u64,
    pub play_count: u32,
    /// 最近一次播放的时间（Unix 毫秒；`save_position` 与 `mark_played` 都写它）。
    pub last_played_at: i64,
}

/// 「继续播放」的落点：上次在放的那一首，以及听到哪儿了。
///
/// 与 [`PlayState`] 分开是因为界面要的是「这一首 + 位置」这一件事，
/// 而不是计数与时间戳；`track` 直接带上，省得界面再查一次。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResumePoint {
    pub track: Track,
    pub position_ms: u64,
}

/// 队列里的一项。
///
/// 只带 id + 路径：够重建播放队列了（引擎要的就是这两样），
/// 不必为了「接着放」把标题、专辑、封面这些元数据也存一遍。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct QueueTrack {
    pub id: TrackId,
    pub path: String,
}

/// 上次的播放队列：整队接着放要用。
///
/// 为什么不复用 [`ResumePoint`]：那个的语义是「上次听的是哪首、听到哪」，
/// 界面拿它只够把**一首歌**摆回播放条上。用户要的是重启之后整队还在——
/// 只有那一首的话，「下一曲」在重启后就是个死键（真机上就是这么被发现的）。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResumeQueue {
    /// 队列本身，顺序就是播放顺序。曲目已被移除的不会出现在这里。
    pub entries: Vec<QueueTrack>,
    /// 上次停在队列里的第几个；一定落在 `entries` 范围内。
    pub index: u32,
    /// 那一首听到哪儿了。
    pub position_ms: u64,
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
