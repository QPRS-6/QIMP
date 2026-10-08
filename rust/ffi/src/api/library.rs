//! 曲库接口：打开索引数据库、扫描目录、查询歌曲。
//!
//! 线程模型：SQLite 连接是 `Send` 但不是 `Sync`（见 core 的 `Db` 文档），
//! 所以这里用一把全局 `Mutex` 把整个进程的曲库句柄包起来。
//! FRB 的异步函数跑在它自己的线程池上，这把锁正好保证互斥。

use std::path::Path;
use std::sync::Mutex;

use flutter_rust_bridge::frb;

use musicplayer_audio::RepeatMode;
use musicplayer_core::db::Scope;
use musicplayer_core::{scan_roots, Db, ScanOptions};

/// 排序方向：Dart 用的是 `descending`，core 用的是枚举，转换写在一处。
fn order_of(descending: bool) -> SortOrder {
    if descending {
        SortOrder::Descending
    } else {
        SortOrder::Ascending
    }
}

// FRB 的 mirror 要求被镜像的类型在本 crate 内“公开可见”，因此显式 re-export。
// 注意：凡是出现在 pub 函数签名里的类型（如 ScanMode）都必须在这里公开导出，
// 否则生成代码引用 `crate::api::library::ScanMode` 时会撞上“私有 import”编译错误。
// 这些名字同时也决定了 Dart 侧看到的类型名。
pub use musicplayer_core::{
    Album, Artist, Playlist, PlaylistFileFormat, PlaylistImport, QueueTrack, ResumePoint,
    ResumeQueue, ScanMode, ScanSummary, SortKey, SortOrder, Stats, Track,
};
// 歌词类型也要出现在 pub 签名里（`track_lyrics` 的返回值），所以同样显式导出。
pub use musicplayer_core::lyric::{LyricLine, LyricWord, Lyrics};

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

/// 一首歌的歌词：**同目录同名的 `.lrc` 优先**，其次文件里内嵌的歌词
/// （判断规则都在 core 的 `metadata::read_lyrics` 里）。
///
/// 两处都没有、id 不存在、曲库没打开——统统返回 `null`：界面上显示一句“没有歌词”
/// 就够了，不该让播放界面出错。
///
/// 异步：要读磁盘上的 `.lrc` 或整份标签，别卡住 UI 线程（与 [`track_cover`] 一致）。
pub fn track_lyrics(track_id: i64) -> Option<Lyrics> {
    let track = track_or_none(track_id)?;
    musicplayer_core::metadata::read_lyrics(&track.path)
        .ok()
        .flatten()
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

/// 索引里的**全部**歌曲（含尚未收进曲库的）。`limit = None` 表示不限条数。
///
/// 界面平时要的是 [`list_library_tracks`]；这个留给“索引里到底有什么”的场合。
#[frb(sync)]
pub fn list_tracks(
    sort: SortKey,
    descending: bool,
    limit: Option<u32>,
) -> Result<Vec<Track>, String> {
    with_db(|db| {
        db.all_tracks(sort, order_of(descending), limit)
            .map_err(|e| e.to_string())
    })
}

/// **曲库**里的歌曲（主页与「我的音乐」看的就是这一份）。`limit = None` 表示不限条数。
#[frb(sync)]
pub fn list_library_tracks(
    sort: SortKey,
    descending: bool,
    limit: Option<u32>,
) -> Result<Vec<Track>, String> {
    with_db(|db| {
        db.library_tracks(sort, order_of(descending), limit)
            .map_err(|e| e.to_string())
    })
}

/// 建了索引、但不在曲库里的歌：扫描发现的新文件，以及被用户移出去的。
///
/// 主页上「＋ 添加歌曲」列的就是这一份（没有它，用户就没有地方把歌加回来）。
#[frb(sync)]
pub fn list_pending_tracks(limit: Option<u32>) -> Result<Vec<Track>, String> {
    with_db(|db| db.pending_tracks(limit).map_err(|e| e.to_string()))
}

/// 把歌曲收进曲库，返回真正加进去的条数。
///
/// 「添加歌曲」一次可能选几十首，所以接口收一批 id，而不是让界面一首一首调。
#[frb(sync)]
pub fn add_to_library(track_ids: Vec<i64>) -> Result<u32, String> {
    with_db(|db| {
        db.set_in_library(&track_ids, true)
            .map(|count| count as u32)
            .map_err(|e| e.to_string())
    })
}

/// 把歌曲移出曲库，返回真正移出的条数。
///
/// **只清标记**：索引记录与磁盘上的文件都留着，所以还能在「＋ 添加歌曲」里原样找回来。
/// 要把文件也删掉是 [`delete_from_storage`] 的事。
#[frb(sync)]
pub fn remove_from_library(track_ids: Vec<i64>) -> Result<u32, String> {
    with_db(|db| {
        db.set_in_library(&track_ids, false)
            .map(|count| count as u32)
            .map_err(|e| e.to_string())
    })
}

/// 「从储存中删除」的结果：删掉了几个文件，以及删不掉的（附原因）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeleteSummary {
    pub deleted: u32,
    pub failed: Vec<String>,
}

/// 把歌曲**从储存里删掉**（文件 + 索引记录），返回删掉的文件数。
///
/// 这是整个应用里唯一会动用户文件的操作，界面必须先问清楚；收的是一批 id。
/// 单个文件删不掉（权限、被别处占用）不打断整批：记进 `failed` 交给界面显示。
/// 索引记录只在磁盘上确实没有这个文件时才删——留着一条指向“不存在的文件”的记录，
/// 只会让界面显示一堆播不了的行。
pub fn delete_from_storage(track_ids: Vec<i64>) -> Result<DeleteSummary, String> {
    // 先把路径取出来：记录删掉之后就查不到它们了。
    let tracks = with_db(|db| db.tracks_by_ids(&track_ids).map_err(|e| e.to_string()))?;

    let mut summary = DeleteSummary {
        deleted: 0,
        failed: Vec::new(),
    };
    let mut gone: Vec<String> = Vec::new();
    for track in tracks {
        match std::fs::remove_file(&track.path) {
            Ok(()) => {
                summary.deleted += 1;
                gone.push(track.path);
            }
            // 文件本来就不在：这一行记录也没有留着的意义，照样清掉。
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => gone.push(track.path),
            Err(err) => summary.failed.push(format!("{}：{err}", track.path)),
        }
    }
    if !gone.is_empty() {
        with_db(|db| db.delete_paths(&gone).map_err(|e| e.to_string()))?;
    }
    Ok(summary)
}

/// 模糊搜索标题 / 艺术家 / 专辑。
///
/// 搜的是**曲库**：界面上的搜索框过滤的正是下面那份曲库列表，搜出没入库的歌
/// 只会让人以为它已经在曲库里了。
#[frb(sync)]
pub fn search_tracks(query: String, limit: u32) -> Result<Vec<Track>, String> {
    with_db(|db| {
        db.search(&query, limit, Scope::Library)
            .map_err(|e| e.to_string())
    })
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
///
/// 只算**曲库**里的歌——它喂给主页底部那行数字，用户看的就是自己挑进来的那些。
#[frb(sync)]
pub fn library_stats() -> Result<Stats, String> {
    with_db(|db| db.library_stats().map_err(|e| e.to_string()))
}

// ---------------------------------------------------------------------------
// 播放列表。
//
// 全是 `#[frb(sync)]`：都是本地 SQLite 的单条读写，快到不值得让 Dart 侧到处 await；
// 界面上的抽屉与列表页都直接调用它们。
// ---------------------------------------------------------------------------

/// 所有播放列表（按名字排序）。
#[frb(sync)]
pub fn playlists() -> Result<Vec<Playlist>, String> {
    with_db(|db| db.playlists().map_err(|e| e.to_string()))
}

/// 新建播放列表，返回它的 id。空名字由核心兜底成“新建列表”。
#[frb(sync)]
pub fn create_playlist(name: String) -> Result<i64, String> {
    with_db(|db| db.create_playlist(&name).map_err(|e| e.to_string()))
}

/// 改名。界面负责拦住空名字：核心只会 trim，不会拒绝空串。
#[frb(sync)]
pub fn rename_playlist(playlist_id: i64, name: String) -> Result<(), String> {
    with_db(|db| {
        db.rename_playlist(playlist_id, &name)
            .map_err(|e| e.to_string())
    })
}

/// 删除播放列表。里面的条目一起没了，曲目本身不动。
#[frb(sync)]
pub fn delete_playlist(playlist_id: i64) -> Result<(), String> {
    with_db(|db| db.delete_playlist(playlist_id).map_err(|e| e.to_string()))
}

/// 把一首歌追加到列表末尾。已经在列表里时返回 `false`（同一列表不重复）。
#[frb(sync)]
pub fn add_to_playlist(playlist_id: i64, track_id: i64) -> Result<bool, String> {
    with_db(|db| {
        db.add_to_playlist(playlist_id, track_id)
            .map_err(|e| e.to_string())
    })
}

/// 从列表里移除一首歌，返回是否真的删掉了。
///
/// 收的是**曲目 id** 而不是下标：下标（position）会在曲目被重扫移除后留下空洞，
/// 界面按行删的是“这一行那一首歌”。
#[frb(sync)]
pub fn remove_from_playlist(playlist_id: i64, track_id: i64) -> Result<bool, String> {
    with_db(|db| {
        db.remove_track_from_playlist(playlist_id, track_id)
            .map_err(|e| e.to_string())
    })
}

/// 列表里的曲目，按用户排的顺序返回。
#[frb(sync)]
pub fn playlist_tracks(playlist_id: i64) -> Result<Vec<Track>, String> {
    with_db(|db| db.playlist_tracks(playlist_id).map_err(|e| e.to_string()))
}

/// 导入一份播放列表**文件**（m3u / m3u8 / xspf），返回新建列表的 id 与统计。
///
/// 收的是文件内容而不是路径：Android 上用户是用系统文件选择器挑的，拿到的只有
/// `content://`，Dart 侧把它读成字节再传进来（见 Dart 的 `PlaylistFiles`）。
/// 列表文件通常只有几十 KB，走一次消息通道不算什么；解析放在 core 里，
/// 于是各种脏数据都能在宿主机上测（见 `musicplayer_core::playlist_file`）。
///
/// 异步：解析 + 建列表可能有几百条，不占着 UI 线程。
///
/// **对不上曲库的条目只是被跳过并计数**（`missing` / `missing_paths`），
/// 不替用户建索引记录——没扫到过是「扫描」该处理的事。
pub fn import_playlist(file_name: String, bytes: Vec<u8>) -> Result<PlaylistImport, String> {
    let parsed =
        musicplayer_core::playlist_file::parse(&file_name, &bytes).map_err(|e| e.to_string())?;

    // 名字优先级：文件里写的（xspf 的 <title>）→ 文件名（去掉扩展名）。
    let name = parsed
        .name
        .as_deref()
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| default_playlist_name(&file_name));

    let skipped = parsed.skipped;
    with_db(|db| {
        let mut result = db
            .import_playlist(&name, &parsed.entries)
            .map_err(|e| e.to_string())?;
        // 网络条目在解析那一步就被剔掉了，只有解析结果知道有几条。
        result.skipped = skipped;
        Ok(result)
    })
}

/// 从文件名里凑一个列表名：`夜跑.m3u8` → `夜跑`。
fn default_playlist_name(file_name: &str) -> String {
    let stem = Path::new(file_name)
        .file_stem()
        .and_then(|stem| stem.to_str())
        .unwrap_or_default()
        .trim();
    if stem.is_empty() {
        "导入的列表".to_string()
    } else {
        stem.to_string()
    }
}

/// 把播放列表导出成**文本**（m3u8 / xspf），由 Dart 侧落盘。
///
/// 为什么不在这里直接写文件：Android 上「保存到哪里」是用户用系统对话框选的，
/// 落盘只能是拿着 `content://` 的那一侧（Kotlin）去写。这里只负责生成内容，
/// 于是格式相关的逻辑全都能在宿主机上测。
#[frb(sync)]
pub fn export_playlist(playlist_id: i64, format: PlaylistFileFormat) -> Result<String, String> {
    with_db(|db| {
        let playlist = db
            .playlist_by_id(playlist_id)
            .map_err(|e| e.to_string())?
            .ok_or_else(|| "这个播放列表已经不在了".to_string())?;
        let tracks = db.playlist_tracks(playlist_id).map_err(|e| e.to_string())?;
        Ok(musicplayer_core::playlist_file::export(
            format,
            &playlist.name,
            &tracks,
        ))
    })
}

// ---------------------------------------------------------------------------
// 「继续播放」。
//
// 同样是 `#[frb(sync)]`：单行 upsert / 单行查询，写在上百毫秒级的轮询里也不心虚；
// 界面在暂停、切歌、退到后台时各调一次 `save_playback_position`。
// ---------------------------------------------------------------------------

/// 上次听到哪儿了（曲目 + 位置）；从没放过东西时为 `null`。
#[frb(sync)]
pub fn resume_point() -> Result<Option<ResumePoint>, String> {
    with_db(|db| db.resume_point().map_err(|e| e.to_string()))
}

/// 上次的播放队列（整队接着放）；从没记过队列时为 `null`。
///
/// 与 [`resume_point`] 的分工：那个回答「上次听的是哪一首、听到哪」，
/// 这个回答「当时听的是哪一整队」。启动时用这一份还原播放队列——
/// 只有单曲的话，重启之后「下一曲」就是个死键（真机上就是这么被发现的）。
#[frb(sync)]
pub fn resume_queue() -> Result<Option<ResumeQueue>, String> {
    with_db(|db| db.resume_queue().map_err(|e| e.to_string()))
}

/// 记下整份播放队列与当前项。队列换了、或者当前项换了就该调它。
///
/// 收的是**整份 id 列表**而不是增量：队列通常几十上百项，一次写清楚更省心，
/// 也不会出现「本地那份和库里那份对不上」的中间状态。
#[frb(sync)]
pub fn save_play_queue(track_ids: Vec<i64>, index: u32) -> Result<(), String> {
    with_db(|db| {
        db.save_queue(&track_ids, index as usize)
            .map_err(|e| e.to_string())
    })
}

/// 记下当前这首的播放进度，下次启动就能从这里接着放。
///
/// 顺手补一次时长：曲库里那份还是 0（标签里没写）时，用解码器从容器里算出来的值填上。
/// 不补的话这类文件在列表里永远是 `--:--`（真机上遇到过：从 mp4 里扒出来、
/// 名字叫 `.mp3` 的音频，标签能读出标题却读不出时长）。
#[frb(sync)]
pub fn save_playback_position(track_id: i64, position_ms: u64) -> Result<(), String> {
    with_db(|db| {
        db.save_position(track_id, position_ms)
            .map_err(|e| e.to_string())?;
        if let Some(duration_ms) = engine_duration_ms(track_id) {
            db.fill_duration(track_id, duration_ms)
                .map_err(|e| e.to_string())?;
        }
        Ok(())
    })
}

/// 记下随机播放与循环模式（界面在退到后台时写一次，下次启动照旧）。
///
/// 收的是**枚举**而不是编码：编码是内部约定（见 `RepeatMode::code`），
/// 让调用方去拼 0/1/2 只会在某一层悄悄写错。
#[frb(sync)]
pub fn save_playback_mode(shuffle: bool, repeat: RepeatMode) -> Result<(), String> {
    with_db(|db| {
        db.save_playback_mode(shuffle, repeat.code())
            .map_err(|e| e.to_string())
    })
}

/// 上次的「随机播放 / 循环模式」；从没记过时为 `null`。
#[frb(sync)]
pub fn playback_mode() -> Result<Option<PlaybackMode>, String> {
    with_db(|db| {
        Ok(db
            .playback_mode()
            .map_err(|e| e.to_string())?
            .map(|(shuffle, repeat_code)| PlaybackMode {
                shuffle,
                repeat: RepeatMode::from_code(repeat_code),
            }))
    })
}

/// 上次的随机播放 / 循环模式（给 Dart 的形状：循环模式是枚举，不是编码）。
pub struct PlaybackMode {
    pub shuffle: bool,
    pub repeat: RepeatMode,
}

/// 解码器已经知道、但曲库里还是 0 的那个时长；没得补时返回 `None`。
fn engine_duration_ms(track_id: i64) -> Option<u64> {
    let snapshot = crate::api::player::snapshot_or_none()?;
    // 引擎里装的必须是同一首：切歌途中调用可能拿到上一首的时长，那就别填。
    if snapshot.track_id != track_id || snapshot.duration_ms == 0 {
        return None;
    }
    Some(snapshot.duration_ms)
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

/// [`musicplayer_core::Playlist`] 的镜像。
#[frb(mirror(Playlist))]
pub struct _Playlist {
    pub id: i64,
    pub name: String,
    pub track_count: u32,
    pub created_at: i64,
}

/// [`musicplayer_core::PlaylistImport`] 的镜像：导入一份列表文件的结果。
///
/// Dart 侧拿它拼那句提示（「已导入 N 首」/「有 M 条对不上」），
/// 所以对不上的前几条（`missing_paths`）也带过来，用户可以自己看一眼是哪些。
#[frb(mirror(PlaylistImport))]
pub struct _PlaylistImport {
    pub playlist_id: i64,
    pub added: u32,
    pub missing: u32,
    pub missing_paths: Vec<String>,
    pub skipped: u32,
}

/// [`musicplayer_core::PlaylistFileFormat`] 的镜像：导入 / 导出认的两种文件格式。
#[frb(mirror(PlaylistFileFormat))]
pub enum _PlaylistFileFormat {
    M3u,
    Xspf,
}

/// [`musicplayer_core::ResumePoint`] 的镜像。
///
/// `track` 直接复用上面那个 [`musicplayer_core::Track`] 镜像，
/// 所以 Dart 侧拿到的是同一个 `Track` 类型（界面不用做任何转换）。
#[frb(mirror(ResumePoint))]
pub struct _ResumePoint {
    pub track: Track,
    pub position_ms: u64,
}

/// [`musicplayer_core::QueueTrack`] 的镜像：队列里的一项。
///
/// 与播放引擎那份 `QueueEntry`（`api::player`）字段一致，但两边各自独立：
/// 那一份是「要送去播放的」，这一份是「上次存下来的」。
#[frb(mirror(QueueTrack))]
pub struct _QueueTrack {
    pub id: i64,
    pub path: String,
}

/// [`musicplayer_core::ResumeQueue`] 的镜像：上次的整份播放队列。
#[frb(mirror(ResumeQueue))]
pub struct _ResumeQueue {
    pub entries: Vec<QueueTrack>,
    pub index: u32,
    pub position_ms: u64,
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

/// [`musicplayer_core::lyric::LyricWord`] 的镜像：逐字歌词里的一小段。
#[frb(mirror(LyricWord))]
pub struct _LyricWord {
    /// 起始时间（毫秒）。
    pub time_ms: u64,
    pub text: String,
}

/// [`musicplayer_core::lyric::LyricLine`] 的镜像：一行歌词。
#[frb(mirror(LyricLine))]
pub struct _LyricLine {
    /// 起始时间（毫秒）；不同步的歌词里统一是 0。
    pub time_ms: u64,
    pub text: String,
    /// 逐字时间轴；空表示这一行没有逐字信息（界面按整行高亮）。
    pub words: Vec<LyricWord>,
}

/// [`musicplayer_core::lyric::Lyrics`] 的镜像。
#[frb(mirror(Lyrics))]
pub struct _Lyrics {
    pub lines: Vec<LyricLine>,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub offset_ms: i64,
    /// 有没有可用的时间轴；`false` 表示纯文本歌词（界面上不做高亮与自动滚动）。
    pub synced: bool,
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

        // 扫描**只建索引**：刚扫完它还在「待入库」里，曲库是空的、也搜不到。
        assert!(
            list_library_tracks(SortKey::Path, false, None)
                .expect("列曲库")
                .is_empty(),
            "扫描不该把文件自动塞进曲库"
        );
        assert_eq!(
            list_pending_tracks(None).expect("待入库").len(),
            1,
            "扫到的文件应出现在待入库列表里"
        );
        assert_eq!(library_stats().expect("统计").track_count, 0);
        assert!(
            search_tracks("demo".to_string(), 10)
                .expect("搜索")
                .is_empty(),
            "还没入库的歌不该被搜出来"
        );

        // 用户把它收进曲库：列表 / 搜索 / 统计一起就位。
        assert_eq!(add_to_library(vec![tracks[0].id]).expect("加入曲库"), 1);
        assert_eq!(
            list_library_tracks(SortKey::Path, false, None)
                .expect("列曲库")
                .len(),
            1
        );
        assert!(list_pending_tracks(None).expect("待入库").is_empty());
        assert_eq!(
            search_tracks("demo".to_string(), 10).expect("搜索").len(),
            1
        );

        let stats = library_stats().expect("统计");
        assert_eq!(stats.track_count, 1);
        assert!(stats.total_duration_ms >= 1900);

        // 移出曲库：索引与文件都还在（能在待入库里找回来），只是曲库视图里没了。
        assert_eq!(
            remove_from_library(vec![tracks[0].id]).expect("移出曲库"),
            1
        );
        assert!(list_library_tracks(SortKey::Path, false, None)
            .expect("列曲库")
            .is_empty());
        assert_eq!(list_pending_tracks(None).expect("待入库").len(), 1);
        assert_eq!(add_to_library(vec![tracks[0].id]).expect("再加回来"), 1);
        assert_eq!(
            list_library_tracks(SortKey::Path, false, None)
                .expect("列曲库")
                .len(),
            1
        );

        // 封面：同目录的 cover.jpg 应该能取到（MIME 由 core 按魔数嗅探）。
        let cover = track_cover(tracks[0].id).expect("有 cover.jpg 时应该能取到封面");
        assert_eq!(cover.mime, "image/jpeg");
        assert_eq!(cover.data, [0xFF, 0xD8, 0xFF, 0x00]);
        assert!(track_cover(999_999).is_none(), "不存在的 id 应返回 None");

        // 歌词：同目录同名的 `.lrc` 应被读到；没有就返回 None（不是报错）。
        assert!(
            track_lyrics(tracks[0].id).is_none(),
            "既没有 .lrc 也没有内嵌歌词时应返回 None"
        );
        std::fs::write(music.join("demo.lrc"), "[00:01.00]第一句\n").expect("写歌词");
        let lyrics = track_lyrics(tracks[0].id).expect("应读到同目录的 .lrc");
        assert!(lyrics.synced, "带时间戳的 .lrc 应当是同步歌词");
        assert_eq!(lyrics.lines.len(), 1);
        assert_eq!(lyrics.lines[0].text, "第一句");
        assert!(track_lyrics(999_999).is_none(), "不存在的 id 应返回 None");

        let again = scan_library(vec![root.clone()], ScanMode::Incremental).expect("增量再扫");
        assert_eq!(again.added, 0, "增量扫描不该重复入库：{again:?}");
        assert_eq!(again.skipped, 1, "未变化的文件应被跳过：{again:?}");

        // 播放列表走一遍 FFI 表面：这一段是给 Dart 侧（抽屉 / 列表页）的契约。
        let list = create_playlist(" 我的列表 ".to_string()).expect("新建列表");
        let listed = playlists().expect("列出列表");
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].name, "我的列表");
        assert_eq!(listed[0].track_count, 0);

        let track_id = tracks[0].id;
        assert!(add_to_playlist(list, track_id).expect("加歌"));
        assert!(
            !add_to_playlist(list, track_id).expect("重复加歌"),
            "不该重复"
        );
        assert_eq!(playlists().expect("再列一次")[0].track_count, 1);

        let in_list = playlist_tracks(list).expect("列表里的歌");
        assert_eq!(in_list.len(), 1);
        assert_eq!(in_list[0].id, track_id);

        rename_playlist(list, " 通勤 ".to_string()).expect("改名");
        assert_eq!(playlists().expect("改名后")[0].name, "通勤");

        assert!(remove_from_playlist(list, track_id).expect("移出列表"));
        assert!(
            !remove_from_playlist(list, track_id).expect("再移一次"),
            "应返回 false"
        );
        assert!(playlist_tracks(list).expect("清空后").is_empty());

        // 导入 / 导出：一份 m3u8 里放着刚扫到的那个真路径 + 一条对不上的。
        let m3u8 = format!(
            "#EXTM3U\n#EXTINF:2,Some Artist - demo\n{}\n/music/not-scanned.mp3\n",
            tracks[0].path
        );
        let imported =
            import_playlist("夜跑.m3u8".to_string(), m3u8.into_bytes()).expect("导入 m3u8");
        assert_eq!(imported.added, 1, "真路径要认出来：{imported:?}");
        assert_eq!(imported.missing, 1, "没扫到的那条只计数：{imported:?}");
        assert_eq!(imported.missing_paths, vec!["/music/not-scanned.mp3"]);
        assert_eq!(
            playlists()
                .expect("列出列表")
                .iter()
                .find(|playlist| playlist.id == imported.playlist_id)
                .expect("导入应建出一个列表")
                .name,
            "夜跑",
            "m3u 没有列表名，用文件名（去掉扩展名）"
        );

        // 列表里的歌要和曲库对得上（导入走的是同一份路径索引）。
        let imported_tracks = playlist_tracks(imported.playlist_id).expect("导入列表的歌");
        assert_eq!(imported_tracks.len(), 1);
        assert_eq!(imported_tracks[0].id, track_id);

        // 导出成两种格式：内容分别认得出来，而且能被自己再解析回去。
        let as_m3u8 =
            export_playlist(imported.playlist_id, PlaylistFileFormat::M3u).expect("导出 m3u8");
        assert!(as_m3u8.starts_with("#EXTM3U\n"), "{as_m3u8}");
        assert!(as_m3u8.contains(&tracks[0].path), "{as_m3u8}");

        let as_xspf =
            export_playlist(imported.playlist_id, PlaylistFileFormat::Xspf).expect("导出 xspf");
        assert!(as_xspf.contains("<title>夜跑</title>"), "{as_xspf}");
        let round_trip = import_playlist("再来一次.xspf".to_string(), as_xspf.into_bytes())
            .expect("把自己导出的 xspf 再导进来");
        assert_eq!(
            round_trip.added, 1,
            "导出的路径要能原样认回来：{round_trip:?}"
        );
        assert_eq!(round_trip.missing, 0);

        assert_eq!(
            export_playlist(9_999, PlaylistFileFormat::M3u).unwrap_err(),
            "这个播放列表已经不在了"
        );

        // 删除列表后统计里的 playlist_count 要跟着降下来。
        assert_eq!(library_stats().expect("统计").playlist_count, 3);
        delete_playlist(list).expect("删除列表");
        assert_eq!(playlists().expect("删完").len(), 2, "导入的两个还在");
        delete_playlist(imported.playlist_id).expect("删掉导入的列表");
        delete_playlist(round_trip.playlist_id).expect("删掉再导入的列表");
        assert!(playlists().expect("全删完").is_empty());
        assert_eq!(library_stats().expect("统计").playlist_count, 0);

        // 「继续播放」的契约：写进度 → 读回同一首、同一位置。
        assert!(resume_point().expect("读进度").is_none(), "从没放过东西");
        save_playback_position(track_id, 12_345).expect("记进度");
        let point = resume_point().expect("读进度").expect("应记得这一首");
        assert_eq!(point.track.id, track_id);
        assert_eq!(point.track.path, tracks[0].path);
        assert_eq!(point.position_ms, 12_345);

        // 文件没了（重扫移除）之后不能再接着放一首不存在的歌：
        // `play_state` 会随曲目级联删除，于是这里自然变回“没什么可接着放”。
        std::fs::remove_file(&tracks[0].path).expect("删掉音频文件");
        let gone = scan_library(vec![root.clone()], ScanMode::Incremental).expect("重扫");
        assert_eq!(gone.removed, 1, "文件没了应被移除：{gone:?}");
        assert!(
            resume_point().expect("读进度").is_none(),
            "曲目没了就别接着放"
        );

        // 「接着上次的听」的契约：整份队列 + 当前项 + 进度，三样都要能读回来。
        // 特意写两首：只有一首的话，「整队都保存下来了」这件事根本看不出来。
        write_wav(&music.join("queue-a.wav"), 1);
        write_wav(&music.join("queue-b.wav"), 1);
        scan_library(vec![root.clone()], ScanMode::Full).expect("扫出要进队列的两首");
        let queue = list_tracks(SortKey::Path, false, None).expect("列出歌曲");
        assert_eq!(queue.len(), 2, "应有两首：{queue:?}");
        let ids: Vec<i64> = queue.iter().map(|track| track.id).collect();

        assert!(
            resume_queue().expect("读队列").is_none(),
            "从没记过队列时不该编一份出来"
        );
        save_play_queue(ids.clone(), 1).expect("记队列");
        save_playback_position(ids[1], 7_777).expect("记进度");

        let saved = resume_queue().expect("读队列").expect("应记得整份队列");
        assert_eq!(
            saved.entries.iter().map(|e| e.id).collect::<Vec<_>>(),
            ids,
            "整队都要在，顺序也一样"
        );
        assert_eq!(saved.entries[0].path, queue[0].path, "路径要带回来给引擎用");
        assert_eq!(saved.index, 1, "上次停在第 2 首");
        assert_eq!(saved.position_ms, 7_777);

        // 文件没了（重扫移除）之后，队列自动变短，当前项也跟着重定位。
        std::fs::remove_file(&queue[0].path).expect("删掉队首那个文件");
        scan_library(vec![root.clone()], ScanMode::Incremental).expect("重扫");
        let saved = resume_queue().expect("读队列").expect("还剩一两首");
        assert!(
            saved.entries.iter().all(|e| e.id != ids[0]),
            "被移除的那首不该还在队列里：{saved:?}"
        );
        assert_eq!(
            saved.entries.iter().map(|e| e.id).collect::<Vec<_>>(),
            vec![ids[1]],
            "只剩第 2 首了"
        );
        assert_eq!(saved.index, 0, "它从第 2 个挪到了第 1 个");
        assert_eq!(saved.position_ms, 7_777, "进度跟着人走");

        // 「退出时记下随机 / 循环」的契约：写进去 → 读回来是同一套；从没记过时是 None
        // （由界面按默认值来，而不是从库里编一个出来）。
        assert!(
            playback_mode().expect("读设置").is_none(),
            "从没记过时不该编一份默认值出来"
        );
        save_playback_mode(true, RepeatMode::One).expect("记设置");
        let mode = playback_mode()
            .expect("读设置")
            .expect("应记得刚写的那一套");
        assert!(mode.shuffle, "随机播放该记下来");
        assert_eq!(mode.repeat, RepeatMode::One, "循环模式该记下来");

        // 再写一次（关随机、列表循环）：两项都得跟着变，不能只改一半。
        save_playback_mode(false, RepeatMode::All).expect("再记一次");
        let mode = playback_mode()
            .expect("读设置")
            .expect("应记得刚写的那一套");
        assert!(!mode.shuffle);
        assert_eq!(mode.repeat, RepeatMode::All);

        // 「从储存中删除」的契约：真的删掉文件，并把它从索引里清掉。
        // 另写一首，免得和上面那条“文件先没了再重扫”的用例纠缠在一起。
        write_wav(&music.join("trash.wav"), 1);
        scan_library(vec![root], ScanMode::Full).expect("扫出要删的那首");
        let victim = list_tracks(SortKey::Path, false, None)
            .expect("列出歌曲")
            .into_iter()
            .find(|track| track.path.ends_with("trash.wav"))
            .expect("应扫到 trash.wav");

        let deleted = delete_from_storage(vec![victim.id]).expect("从储存删除");
        assert_eq!(deleted.deleted, 1, "应删掉 1 个文件：{deleted:?}");
        assert!(deleted.failed.is_empty(), "不该有失败：{deleted:?}");
        assert!(!Path::new(&victim.path).exists(), "文件应真的从磁盘上消失");
        assert!(
            list_tracks(SortKey::Path, false, None)
                .expect("列出歌曲")
                .iter()
                .all(|track| track.id != victim.id),
            "索引记录也应一起清掉"
        );
        assert!(
            delete_from_storage(vec![victim.id])
                .expect("再删一次")
                .deleted
                == 0,
            "已经删过的 id 不该算进删除数量"
        );
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
