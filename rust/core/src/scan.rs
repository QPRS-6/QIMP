//! 目录扫描：发现音频文件 → 读元数据 → 写索引。
//!
//! 关键设计：
//! - **增量扫描靠 (size, mtime) 差异**，不重新解析未变化的文件；这是启动速度的关键。
//! - **删除判定按根目录粒度做保护**：只有某个根目录本次仍扫到了文件，才清理该目录下
//!   “数据库里有、磁盘上没有”的记录。这样 SD 卡未挂载 / 权限被撤销时不会误删整库。
//! - 进度通过回调上报，FFI 层随后把它变成 Dart 的 `Stream`。

use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Instant;

use walkdir::WalkDir;

use crate::db::{unix_now, Db};
use crate::error::Result;
use crate::metadata;
use crate::models::{MediaKind, ScanMode, ScanProgress, ScanSummary};

/// 默认纳入曲库的音频扩展名（全部小写，不含点）。
pub const AUDIO_EXTENSIONS: &[&str] = &[
    "mp3", "flac", "m4a", "m4b", "aac", "ogg", "oga", "opus", "wav", "wave", "wv", "ape", "aiff",
    "aif", "aifc", "mpc", "wma", "mp2", "amr", "dsf", "dff",
];

/// 视频扩展名先留着不扫描，但保留判定能力（后续要支持 MV / 演唱会）。
pub const VIDEO_EXTENSIONS: &[&str] = &["mp4", "mkv", "webm", "avi", "mov", "3gp", "ts", "m4v"];

/// 含此标记文件的目录会被整棵跳过（沿用 Android MediaScanner 的约定）。
const NOMEDIA_MARKER: &str = ".nomedia";

/// Android 上忽略的目录名（系统目录 + 回收站）。
const SKIPPED_DIR_NAMES: &[&str] = &[
    "Android",
    "data",
    "obb",
    "LOST.DIR",
    ".thumbnails",
    ".Trash",
    ".trash",
    "$RECYCLE.BIN",
    "System Volume Information",
];

/// 扫描参数。
#[derive(Debug, Clone)]
pub struct ScanOptions {
    pub mode: ScanMode,
    /// 是否跟随符号链接（Android 上默认关闭，避免 SAF 目录成环）。
    pub follow_links: bool,
    /// 最大递归深度，`None` 表示不限制。
    pub max_depth: Option<usize>,
    /// 是否清理磁盘上已消失的记录。
    pub prune_missing: bool,
}

impl Default for ScanOptions {
    fn default() -> Self {
        ScanOptions {
            mode: ScanMode::Incremental,
            follow_links: false,
            max_depth: None,
            prune_missing: true,
        }
    }
}

/// 返回一份扩展名清单（给 UI 的“支持格式”展示用）。
pub fn default_audio_extensions() -> Vec<String> {
    AUDIO_EXTENSIONS.iter().map(|s| (*s).to_string()).collect()
}

/// 取小写扩展名。
pub fn extension_of(path: &Path) -> Option<String> {
    path.extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_ascii_lowercase())
}

/// 是否是音频文件（只看扩展名，不看内容；内容判定交给 lofty）。
pub fn is_audio_path(path: &Path) -> bool {
    matches!(media_kind(path), Some(MediaKind::Audio))
}

/// 按扩展名判断媒体类型。
pub fn media_kind(path: &Path) -> Option<MediaKind> {
    let ext = extension_of(path)?;
    if AUDIO_EXTENSIONS.contains(&ext.as_str()) {
        Some(MediaKind::Audio)
    } else if VIDEO_EXTENSIONS.contains(&ext.as_str()) {
        Some(MediaKind::Video)
    } else {
        None
    }
}

/// 扫描发现的单个文件（含判定增量用的文件戳）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiscoveredFile {
    pub path: PathBuf,
    pub size_bytes: u64,
    pub modified_at: i64,
}

/// 递归发现某个根目录下的音频文件。
///
/// 会跳过：隐藏目录（`.` 开头）、Android 系统目录（`Android/data` 等）、
/// 以及放了 `.nomedia` 的目录（沿用 Android 媒体库的约定）。
/// 注意：这些规则**不作用于传入的根目录自身**。
pub fn discover_files(root: &Path, opts: &ScanOptions) -> Vec<DiscoveredFile> {
    let mut walker = WalkDir::new(root).follow_links(opts.follow_links);
    if let Some(depth) = opts.max_depth {
        walker = walker.max_depth(depth);
    }

    let mut out = Vec::new();
    let entries = walker.into_iter().filter_entry(|entry| {
        // depth == 0 是遍历的根目录本身：用户明确选定的目录永远放行，
        // 不能被“跳过隐藏目录”之类的规则挡掉（否则它的整棵子树都会消失）。
        if entry.depth() == 0 || !entry.file_type().is_dir() {
            return true;
        }
        let name = entry.file_name().to_string_lossy();
        if name.starts_with('.') || SKIPPED_DIR_NAMES.contains(&name.as_ref()) {
            return false;
        }
        // 放了 .nomedia 的目录 = 用户明确不想被扫描。
        !entry.path().join(NOMEDIA_MARKER).exists()
    });

    for entry in entries.flatten() {
        if !entry.file_type().is_file() || !is_audio_path(entry.path()) {
            continue;
        }
        let Ok(meta) = entry.metadata() else {
            continue;
        };
        let modified_at = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        out.push(DiscoveredFile {
            path: entry.path().to_path_buf(),
            size_bytes: meta.len(),
            modified_at,
        });
    }

    out.sort_by(|a, b| a.path.cmp(&b.path));
    out
}

fn normalize_root(root: &Path) -> String {
    root.to_string_lossy().trim_end_matches('/').to_string()
}

/// 目录里是否有任意条目（含子目录与隐藏文件）。
///
/// 用来区分“用户真的把音乐删空了”和“存储挂载点还在、内容还没挂上来”——
/// 后者一旦被误判就会清空整个曲库，所以读不到内容时一律返回 `false`。
fn has_any_entry(dir: &str) -> bool {
    match fs::read_dir(dir) {
        Ok(mut entries) => entries.next().is_some(),
        Err(_) => false,
    }
}

/// 扫描一组根目录并把结果写入索引。
///
/// 返回值明确区分 added / updated / skipped / removed / failed，
/// 便于 UI 告诉用户“本次新增 12 首，跳过 3000 首未变化文件”。
pub fn scan_roots<P: AsRef<Path>>(
    db: &Db,
    roots: &[P],
    opts: &ScanOptions,
    progress: &mut dyn FnMut(ScanProgress),
) -> Result<ScanSummary> {
    let started = Instant::now();
    let mut summary = ScanSummary::default();

    // ---- 1) 发现：逐个根目录收集 ----
    let mut per_root: Vec<(String, Vec<DiscoveredFile>)> = Vec::new();
    for root in roots {
        let root = root.as_ref();
        // 根目录不存在（存储未挂载 / 授权被撤销）时跳过，并且**不参与剪枝**。
        if !root.is_dir() {
            continue;
        }
        per_root.push((normalize_root(root), discover_files(root, opts)));
    }

    let total: usize = per_root.iter().map(|(_, files)| files.len()).sum();
    progress(ScanProgress {
        scanned: 0,
        total: total as u32,
        current_path: String::new(),
    });

    // ---- 2) 差异：决定哪些文件需要重新读元数据 ----
    let known = db.known_files()?;
    let mut seen: HashSet<String> = HashSet::with_capacity(total);
    let mut pending: Vec<DiscoveredFile> = Vec::new();

    for (_, files) in &per_root {
        for file in files {
            let key = file.path.to_string_lossy().into_owned();
            // 多个根目录互相嵌套时会重复发现同一个文件，这里去重。
            if !seen.insert(key.clone()) {
                continue;
            }
            let unchanged = matches!(
                (opts.mode, known.get(&key)),
                (ScanMode::Incremental, Some(stamp))
                    if stamp.size_bytes == file.size_bytes && stamp.modified_at == file.modified_at
            );
            if unchanged {
                summary.skipped += 1;
            } else {
                pending.push(file.clone());
            }
        }
    }

    // ---- 3) 逐个读取并入库 ----
    // 这里**只建索引**：新行的 `in_library` 走列默认值 0，也就是不会自动进曲库，
    // 收不收进来由用户在主页上决定（`upsert_track` 在冲突分支也刻意不碰这个标记）。
    for (index, file) in pending.iter().enumerate() {
        let key = file.path.to_string_lossy().into_owned();
        progress(ScanProgress {
            scanned: index as u32,
            total: pending.len() as u32,
            current_path: key.clone(),
        });

        let existed = known.contains_key(&key);
        match metadata::read(&file.path) {
            Ok(mut track) => {
                if !existed {
                    track.added_at = unix_now();
                }
                db.upsert_track(&track)?;
                if existed {
                    summary.updated += 1;
                } else {
                    summary.added += 1;
                }
            }
            Err(err) => {
                summary.failed += 1;
                summary.errors.push(err.to_string());
            }
        }
    }

    // ---- 4) 剪枝：只有“该根目录本次确实扫到了文件”时才删除，避免误删整库 ----
    if opts.prune_missing {
        for (root, files) in &per_root {
            // 目录整个空掉时不敢删：这更可能是“存储没挂上来”而不是“用户删光了音乐”。
            if files.is_empty() && !has_any_entry(root) {
                continue;
            }
            let stale: Vec<String> = db
                .paths_under_root(root)?
                .into_iter()
                .filter(|path| !seen.contains(path))
                .collect();
            summary.removed += db.delete_paths(&stale)? as u32;
        }
    }

    progress(ScanProgress {
        scanned: total as u32,
        total: total as u32,
        current_path: String::new(),
    });
    summary.elapsed_ms = started.elapsed().as_millis() as u64;
    Ok(summary)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::Db;

    fn touch(dir: &Path, relative: &str, bytes: usize) -> PathBuf {
        let file = dir.join(relative);
        if let Some(parent) = file.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(&file, vec![0u8; bytes]).unwrap();
        file
    }

    fn scan(db: &Db, root: &Path, opts: &ScanOptions) -> ScanSummary {
        scan_roots(db, &[root], opts, &mut |_| {}).unwrap()
    }

    fn track_count(db: &Db) -> u32 {
        db.stats().unwrap().track_count
    }

    #[test]
    fn classifies_by_extension_case_insensitively() {
        assert!(is_audio_path(Path::new("/m/a.MP3")));
        assert!(is_audio_path(Path::new("/m/a.FlAc")));
        assert!(!is_audio_path(Path::new("/m/a.txt")));
        assert!(!is_audio_path(Path::new("/m/README")));
        assert_eq!(media_kind(Path::new("/m/v.mp4")), Some(MediaKind::Video));
        assert_eq!(media_kind(Path::new("/m/a.m4a")), Some(MediaKind::Audio));
        assert_eq!(media_kind(Path::new("/m/cover.jpg")), None);
        assert!(default_audio_extensions().contains(&"mp3".to_string()));
    }

    #[test]
    fn discover_skips_hidden_system_and_nomedia_dirs() {
        let dir = tempfile::tempdir().unwrap();
        touch(dir.path(), "keep.mp3", 8);
        touch(dir.path(), "Sub/deep.flac", 8);
        touch(dir.path(), ".hidden/secret.mp3", 8);
        touch(dir.path(), "Android/data/app.mp3", 8);
        touch(dir.path(), "Private/.nomedia", 0);
        touch(dir.path(), "Private/song.mp3", 8);
        touch(dir.path(), "notes.txt", 8);

        let names: Vec<String> = discover_files(dir.path(), &ScanOptions::default())
            .iter()
            .map(|f| f.path.file_name().unwrap().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, vec!["deep.flac", "keep.mp3"]);
    }

    #[test]
    fn discover_respects_max_depth() {
        let dir = tempfile::tempdir().unwrap();
        touch(dir.path(), "top.mp3", 8);
        touch(dir.path(), "a/b/deep.mp3", 8);

        let opts = ScanOptions {
            max_depth: Some(2),
            ..Default::default()
        };
        let names: Vec<String> = discover_files(dir.path(), &opts)
            .iter()
            .map(|f| f.path.file_name().unwrap().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, vec!["top.mp3"]);
    }

    #[test]
    fn does_not_skip_explicit_dot_root() {
        // 根目录自身就算以 `.` 开头也必须被扫描（tempfile 创建的目录名正是 `.tmpXXXX`）。
        let dir = tempfile::tempdir().unwrap();
        touch(dir.path(), "a.mp3", 8);
        let name = dir
            .path()
            .file_name()
            .unwrap()
            .to_string_lossy()
            .into_owned();
        assert!(
            name.starts_with('.'),
            "临时目录名应以 . 开头，实际为 {name}"
        );
        assert_eq!(discover_files(dir.path(), &ScanOptions::default()).len(), 1);
    }

    #[test]
    fn first_scan_indexes_everything_then_skips_unchanged() {
        let dir = tempfile::tempdir().unwrap();
        touch(dir.path(), "a.mp3", 8);
        touch(dir.path(), "b/c.flac", 8);
        let db = Db::open_in_memory().unwrap();

        let mut events: Vec<ScanProgress> = Vec::new();
        let first = scan_roots(&db, &[dir.path()], &ScanOptions::default(), &mut |p| {
            events.push(p)
        })
        .unwrap();

        assert_eq!(first.added, 2);
        assert_eq!(first.updated, 0);
        assert_eq!(first.skipped, 0);
        assert_eq!(first.removed, 0);
        assert_eq!(first.failed, 0);
        assert!(first.errors.is_empty());
        assert_eq!(track_count(&db), 2);

        // 进度：开头报总数，最后一条必须是收尾状态。
        assert_eq!(events.first().unwrap().scanned, 0);
        assert_eq!(events.len(), 4); // 开头 1 条 + 每个文件 1 条 + 结尾 1 条
        let last = events.last().unwrap();
        assert_eq!(last.scanned, last.total);

        // 第二次：文件戳没变 → 全部跳过，且不重复入库。
        let second = scan(&db, dir.path(), &ScanOptions::default());
        assert_eq!(second.added, 0);
        assert_eq!(second.updated, 0);
        assert_eq!(second.skipped, 2);
        assert_eq!(track_count(&db), 2);

        // 全量模式：即使没变化也要重读。
        let full = ScanOptions {
            mode: ScanMode::Full,
            ..Default::default()
        };
        let third = scan(&db, dir.path(), &full);
        assert_eq!(third.updated, 2);
        assert_eq!(third.skipped, 0);
        assert_eq!(track_count(&db), 2);
    }

    #[test]
    fn rescan_detects_modified_file() {
        let dir = tempfile::tempdir().unwrap();
        let file = touch(dir.path(), "a.mp3", 8);
        let db = Db::open_in_memory().unwrap();
        assert_eq!(scan(&db, dir.path(), &ScanOptions::default()).added, 1);

        fs::write(&file, vec![0u8; 64]).unwrap();
        let second = scan(&db, dir.path(), &ScanOptions::default());
        assert_eq!(second.updated, 1);
        assert_eq!(second.skipped, 0);
        assert_eq!(track_count(&db), 1);
    }

    #[test]
    fn prune_removes_deleted_file_but_keeps_others() {
        let dir = tempfile::tempdir().unwrap();
        let gone = touch(dir.path(), "a.mp3", 8);
        touch(dir.path(), "b.mp3", 8);
        let db = Db::open_in_memory().unwrap();
        assert_eq!(scan(&db, dir.path(), &ScanOptions::default()).added, 2);

        fs::remove_file(&gone).unwrap();
        let second = scan(&db, dir.path(), &ScanOptions::default());
        assert_eq!(second.removed, 1);
        assert_eq!(second.skipped, 1);
        assert_eq!(track_count(&db), 1);
    }

    #[test]
    fn prune_runs_even_when_no_audio_is_left() {
        let dir = tempfile::tempdir().unwrap();
        let gone = touch(dir.path(), "a.mp3", 8);
        touch(dir.path(), "readme.txt", 4);
        let db = Db::open_in_memory().unwrap();
        scan(&db, dir.path(), &ScanOptions::default());

        fs::remove_file(&gone).unwrap();
        let second = scan(&db, dir.path(), &ScanOptions::default());
        assert_eq!(second.removed, 1);
        assert_eq!(track_count(&db), 0);
    }

    #[test]
    fn prune_can_be_disabled() {
        let dir = tempfile::tempdir().unwrap();
        let gone = touch(dir.path(), "a.mp3", 8);
        touch(dir.path(), "b.mp3", 8);
        let db = Db::open_in_memory().unwrap();
        scan(&db, dir.path(), &ScanOptions::default());

        fs::remove_file(&gone).unwrap();
        let opts = ScanOptions {
            prune_missing: false,
            ..Default::default()
        };
        let second = scan(&db, dir.path(), &opts);
        assert_eq!(second.removed, 0);
        assert_eq!(track_count(&db), 2);
    }

    #[test]
    fn keeps_library_when_root_is_unmounted() {
        let dir = tempfile::tempdir().unwrap();
        touch(dir.path(), "a.mp3", 8);
        let db = Db::open_in_memory().unwrap();
        let root = dir.path().to_path_buf();
        assert_eq!(scan(&db, &root, &ScanOptions::default()).added, 1);

        drop(dir); // 相当于 SD 卡被拔掉 / 授权被撤销

        let second = scan(&db, &root, &ScanOptions::default());
        assert_eq!(second.removed, 0);
        assert_eq!(track_count(&db), 1);
    }

    #[test]
    fn keeps_library_when_directory_became_empty() {
        let dir = tempfile::tempdir().unwrap();
        let file = touch(dir.path(), "a.mp3", 8);
        let db = Db::open_in_memory().unwrap();
        scan(&db, dir.path(), &ScanOptions::default());

        fs::remove_file(&file).unwrap(); // 目录里一个条目都不剩

        let second = scan(&db, dir.path(), &ScanOptions::default());
        assert_eq!(second.removed, 0);
        assert_eq!(track_count(&db), 1);
    }
}
