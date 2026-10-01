//! 曲库接口：打开索引数据库、扫描目录、查询歌曲。
//!
//! 线程模型：SQLite 连接是 `Send` 但不是 `Sync`（见 core 的 `Db` 文档），
//! 所以这里用一把全局 `Mutex` 把整个进程的曲库句柄包起来。
//! FRB 的异步函数跑在它自己的线程池上，这把锁正好保证互斥。

use std::path::Path;
use std::sync::Mutex;

use flutter_rust_bridge::frb;

use musicplayer_core::{scan_roots, Db, ScanOptions};

// FRB 的 mirror 要求被镜像的类型在本 crate 内“公开可见”，因此显式 re-export。
// 注意：凡是出现在 pub 函数签名里的类型（如 ScanMode）都必须在这里公开导出，
// 否则生成代码引用 `crate::api::library::ScanMode` 时会撞上“私有 import”编译错误。
// 这些名字同时也决定了 Dart 侧看到的类型名。
pub use musicplayer_core::{
    Album, Artist, ScanMode, ScanSummary, SortKey, SortOrder, Stats, Track,
};

/// 进程内唯一的曲库句柄；`None` 表示尚未打开。
static DB: Mutex<Option<Db>> = Mutex::new(None);

/// 统一的“取句柄 → 执行 → 转换错误”包装，避免每个接口都写一遍锁的样板。
fn with_db<T>(action: impl FnOnce(&Db) -> Result<T, String>) -> Result<T, String> {
    let guard = DB
        .lock()
        .map_err(|_| "曲库内部状态异常（锁已中毒）".to_string())?;
    let db = guard
        .as_ref()
        .ok_or("曲库尚未打开，请先调用 open_library")?;
    action(db)
}

/// 按 id 取一首歌。给非 Dart 的 FFI 使用者（Android 通知栏）用：
/// 曲库没打开、或 id 不存在都返回 `None`。
pub(crate) fn track_or_none(id: i64) -> Option<Track> {
    with_db(|db| db.track_by_id(id).map_err(|e| e.to_string()))
        .ok()
        .flatten()
}

/// 封面图：Dart 侧直接把它喂给 `Image.memory`，所以只带 mime 与原始字节。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CoverData {
    pub mime: String,
    pub data: Vec<u8>,
}

/// 一首歌的封面：内嵌图优先，其次同目录的 `cover.jpg` / `folder.jpg` 等约定文件名
/// （判断规则都在 core 的 `metadata::read_cover` 里）。
///
/// 曲库没打开、id 不存在、没有封面、文件读不出来——统统返回 `None`：
/// 界面上退化成一张占位图就够了，不该因为一张图让播放界面报错。
pub fn track_cover(track_id: i64) -> Option<CoverData> {
    let track = track_or_none(track_id)?;
    let cover = musicplayer_core::metadata::read_cover(&track.path)
        .ok()
        .flatten()?;
    Some(CoverData {
        mime: cover.mime,
        data: cover.data,
    })
}

/// Android 上常见的音乐目录，**只返回真实存在的那些**，UI 可直接拿来当扫描根。
///
/// 目录给的是真实路径而不是 SAF 的 `content://`：核心的扫描器基于 `std::fs`，
/// 需要能以普通文件方式打开这些文件（配合“所有文件访问”权限）。
#[frb(sync)]
pub fn suggest_scan_roots() -> Vec<String> {
    const CANDIDATES: &[&str] = &[
        "/storage/emulated/0/Music",
        "/storage/emulated/0/Download",
        "/storage/emulated/0/Podcasts",
        "/storage/emulated/0/Recordings",
        "/storage/emulated/0/Documents",
    ];
    CANDIDATES
        .iter()
        .filter(|path| Path::new(path).is_dir())
        .map(|path| (*path).to_string())
        .collect()
}

/// 打开（不存在则创建）索引数据库。App 启动时调用一次。
///
/// 数据库应放在应用私有目录（Dart 侧用 `path_provider` 取），避免被其它应用改动。
#[frb(sync)]
pub fn open_library(db_path: String) -> Result<(), String> {
    let db = Db::open(&db_path).map_err(|e| e.to_string())?;
    let mut guard = DB
        .lock()
        .map_err(|_| "曲库内部状态异常（锁已中毒）".to_string())?;
    *guard = Some(db);
    Ok(())
}

/// 扫描一组根目录并写入索引；返回本次的新增 / 更新 / 删除 / 跳过统计。
///
/// `mode = incremental` 只重新解析 `(size, mtime)` 变化的文件，启动时首选。
/// 扫描是长任务，故保持异步：Dart 侧拿到的是 `Future`，不阻塞 UI 线程。
pub fn scan_library(roots: Vec<String>, mode: ScanMode) -> Result<ScanSummary, String> {
    let mut guard = DB
        .lock()
        .map_err(|_| "曲库内部状态异常（锁已中毒）".to_string())?;
    let db = guard
        .as_mut()
        .ok_or("曲库尚未打开，请先调用 open_library")?;

    let options = ScanOptions {
        mode,
        ..Default::default()
    };
    // 进度回调暂时丢弃；接 UI 进度条时改成 FRB 的 StreamSink 即可（core 已把回调留好）。
    let mut progress = |_progress: musicplayer_core::ScanProgress| {};
    scan_roots(db, &roots, &options, &mut progress).map_err(|e| e.to_string())
}

/// 列出曲库里的歌曲。`limit = None` 表示不限条数。
#[frb(sync)]
pub fn list_tracks(
    sort: SortKey,
    descending: bool,
    limit: Option<u32>,
) -> Result<Vec<Track>, String> {
    let order = if descending {
        SortOrder::Descending
    } else {
        SortOrder::Ascending
    };
    with_db(|db| db.all_tracks(sort, order, limit).map_err(|e| e.to_string()))
}

/// 模糊搜索标题 / 艺术家 / 专辑。
#[frb(sync)]
pub fn search_tracks(query: String, limit: u32) -> Result<Vec<Track>, String> {
    with_db(|db| db.search(&query, limit).map_err(|e| e.to_string()))
}

/// 专辑聚合列表。
#[frb(sync)]
pub fn list_albums() -> Result<Vec<Album>, String> {
    with_db(|db| db.albums().map_err(|e| e.to_string()))
}

/// 艺术家聚合列表。
#[frb(sync)]
pub fn list_artists() -> Result<Vec<Artist>, String> {
    with_db(|db| db.artists().map_err(|e| e.to_string()))
}

/// 曲库统计（歌曲数 / 专辑数 / 总时长等）。
#[frb(sync)]
pub fn library_stats() -> Result<Stats, String> {
    with_db(|db| db.stats().map_err(|e| e.to_string()))
}

// ---------------------------------------------------------------------------
// 镜像声明：让 Dart 直接使用 core 里的类型，省掉一层手写 DTO。
// 这里只提供类型信息；字段与 core 不一致会**编译报错**，因此不会悄悄跑偏。
// ---------------------------------------------------------------------------

/// [`musicplayer_core::Track`] 的镜像。
#[frb(mirror(Track))]
pub struct _Track {
    pub id: i64,
    pub path: String,
    pub title: String,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub album_artist: Option<String>,
    pub genre: Option<String>,
    pub year: Option<u32>,
    pub track_no: Option<u32>,
    pub disc_no: Option<u32>,
    pub duration_ms: u64,
    pub bitrate: Option<u32>,
    pub sample_rate: Option<u32>,
    pub channels: Option<u8>,
    pub size_bytes: u64,
    pub modified_at: i64,
    pub has_cover: bool,
    pub added_at: i64,
}

/// [`musicplayer_core::Album`] 的镜像。
#[frb(mirror(Album))]
pub struct _Album {
    pub name: String,
    pub album_artist: String,
    pub track_count: u32,
    pub duration_ms: u64,
    pub year: Option<u32>,
    pub has_cover: bool,
}

/// [`musicplayer_core::Artist`] 的镜像。
#[frb(mirror(Artist))]
pub struct _Artist {
    pub name: String,
    pub track_count: u32,
    pub album_count: u32,
}

/// [`musicplayer_core::Stats`] 的镜像。
#[frb(mirror(Stats))]
pub struct _Stats {
    pub track_count: u32,
    pub album_count: u32,
    pub artist_count: u32,
    pub playlist_count: u32,
    pub total_duration_ms: u64,
    pub total_size_bytes: u64,
}

/// [`musicplayer_core::ScanSummary`] 的镜像。
#[frb(mirror(ScanSummary))]
pub struct _ScanSummary {
    pub added: u32,
    pub updated: u32,
    pub removed: u32,
    pub skipped: u32,
    pub failed: u32,
    pub elapsed_ms: u64,
    pub errors: Vec<String>,
}

/// [`musicplayer_core::SortKey`] 的镜像。
#[frb(mirror(SortKey))]
pub enum _SortKey {
    Title,
    Artist,
    Album,
    AddedAt,
    Duration,
    Path,
}

/// [`musicplayer_core::SortOrder`] 的镜像。
#[frb(mirror(SortOrder))]
pub enum _SortOrder {
    Ascending,
    Descending,
}

/// [`musicplayer_core::ScanMode`] 的镜像。
#[frb(mirror(ScanMode))]
pub enum _ScanMode {
    Full,
    Incremental,
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 写一个**合法**的最小 WAV（8 kHz / 单声道 / 8bit PCM）。
    /// 用真文件而不是空壳，这样测试覆盖的是“发现 → 解析元数据 → 入库 → 查询”整条链路。
    fn write_wav(path: &Path, seconds: u32) {
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
        bytes.extend_from_slice(&RATE.to_le_bytes()); // byte rate = 采样率 × 1 声道 × 1 字节
        bytes.extend_from_slice(&1u16.to_le_bytes()); // block align
        bytes.extend_from_slice(&8u16.to_le_bytes()); // 位深
        bytes.extend_from_slice(b"data");
        bytes.extend_from_slice(&data_len.to_le_bytes());
        bytes.extend(std::iter::repeat_n(0x80u8, data_len as usize)); // 8bit 的静音电平
        std::fs::write(path, bytes).expect("写入测试 WAV");
    }

    /// 端到端：扫描真目录 → 入库 → 查询 / 搜索 / 统计 → 再扫一次应全部跳过。
    ///
    /// 只写成一个测试函数：曲库是进程级单例，多个用例并发跑会互相踩。
    #[test]
    fn scan_then_query_roundtrip() {
        let temp = tempfile::tempdir().expect("临时目录");
        let music = temp.path().join("Music");
        std::fs::create_dir_all(&music).expect("建音乐目录");
        write_wav(&music.join("demo.wav"), 2);
        // 同目录放一张封面：core 的封面查找规则（内嵌图 → 约定文件名）里后者更容易造。
        std::fs::write(music.join("cover.jpg"), [0xFF, 0xD8, 0xFF, 0x00]).expect("写封面");

        let db_path = temp.path().join("library.db");
        open_library(db_path.to_string_lossy().to_string()).expect("打开曲库");

        let root = music.to_string_lossy().to_string();

        let summary = scan_library(vec![root.clone()], ScanMode::Full).expect("首次扫描");
        assert_eq!(summary.added, 1, "应索引 1 首：{summary:?}");
        assert_eq!(summary.failed, 0, "不该有失败：{summary:?}");

        let tracks = list_tracks(SortKey::Path, false, None).expect("列出歌曲");
        assert_eq!(tracks.len(), 1);
        assert_eq!(tracks[0].title, "demo", "无标签时应回退到文件名");
        assert!(
            tracks[0].duration_ms >= 1900,
            "时长应被解析出来，实际 {} ms",
            tracks[0].duration_ms
        );

        assert_eq!(
            search_tracks("demo".to_string(), 10).expect("搜索").len(),
            1
        );

        let stats = library_stats().expect("统计");
        assert_eq!(stats.track_count, 1);
        assert!(stats.total_duration_ms >= 1900);

        // 封面：同目录的 cover.jpg 应该能取到（MIME 由 core 按魔数嗅探）。
        let cover = track_cover(tracks[0].id).expect("有 cover.jpg 时应该能取到封面");
        assert_eq!(cover.mime, "image/jpeg");
        assert_eq!(cover.data, [0xFF, 0xD8, 0xFF, 0x00]);
        assert!(track_cover(999_999).is_none(), "不存在的 id 应返回 None");

        let again = scan_library(vec![root], ScanMode::Incremental).expect("增量再扫");
        assert_eq!(again.added, 0, "增量扫描不该重复入库：{again:?}");
        assert_eq!(again.skipped, 1, "未变化的文件应被跳过：{again:?}");
    }

    /// 建议根目录的契约：只给绝对路径，且一定真实存在。
    #[test]
    fn suggested_roots_are_absolute_and_exist() {
        for root in suggest_scan_roots() {
            assert!(Path::new(&root).is_absolute(), "必须是绝对路径：{root}");
            assert!(Path::new(&root).is_dir(), "建议的目录必须存在：{root}");
        }
    }
}
