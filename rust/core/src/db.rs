//! SQLite 索引层。
//!
//! 设计取舍：
//! - **刻意不范式化**。专辑/艺术家直接从 `track` 表 `GROUP BY` 得出，不建独立表。
//!   本地播放器的曲库规模（几千~几万首）下这样更快、更省事，也避免了三张表之间
//!   的一致性维护。将来真的需要艺术家头像之类的数据，再加表也不影响现有 API。
//! - 所有排序字段都走白名单 `match`，绝不把用户输入拼进 SQL。
//! - 路径是唯一键（`UNIQUE(path)`），扫描靠它做 upsert。
//! - **索引 ≠ 曲库**。扫描只往 `track` 里建索引；曲库是其中 `in_library = 1` 的部分，
//!   收不收由用户在界面上决定，升级老库的规则见 [`Db::migrate`]。

use std::collections::HashMap;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{params, Connection, OptionalExtension, Row};

use crate::error::Result;
use crate::models::{
    Album, Artist, PlayState, Playlist, PlaylistId, PlaylistImport, QueueTrack, ResumePoint,
    ResumeQueue, SortKey, SortOrder, Stats, Track, TrackId, MISSING_PREVIEW_LIMIT,
};
use crate::playlist_file::PathIndex;

/// 索引数据库的结构版本。
///
/// - v1：曲目 / 播放列表 / 播放进度。
/// - v2：`track` 增加 `in_library`——「索引里有什么」与「曲库里有什么」从此分开，
///   升级与取舍都写在 [`Db::migrate`] 里。
/// - v3：新增 `play_queue`（整份播放队列 + 当前项）——「接着上次的听」不再只剩一首。
///   新表由 `SCHEMA_SQL` 的 `CREATE TABLE IF NOT EXISTS` 直接建出来，老库不需要额外的
///   升级步骤，所以这里只把它记进 `meta.schema_version`。
pub(crate) const SCHEMA_VERSION: u32 = 3;

const TRACK_COLUMNS: &str = "id, path, title, artist, album, album_artist, genre, year, \
     track_no, disc_no, duration_ms, bitrate, sample_rate, channels, size_bytes, modified_at, \
     has_cover, added_at";

const SCHEMA_SQL: &str = r#"
CREATE TABLE IF NOT EXISTS track (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    path         TEXT    NOT NULL UNIQUE,
    title        TEXT    NOT NULL DEFAULT '',
    artist       TEXT,
    album        TEXT,
    album_artist TEXT,
    genre        TEXT,
    year         INTEGER,
    track_no     INTEGER,
    disc_no      INTEGER,
    duration_ms  INTEGER NOT NULL DEFAULT 0,
    bitrate      INTEGER,
    sample_rate  INTEGER,
    channels     INTEGER,
    size_bytes   INTEGER NOT NULL DEFAULT 0,
    modified_at  INTEGER NOT NULL DEFAULT 0,
    has_cover    INTEGER NOT NULL DEFAULT 0,
    added_at     INTEGER NOT NULL DEFAULT 0,
    -- 是否在「曲库」里：扫描只负责建索引（0），收不收进曲库由用户在界面上决定。
    in_library   INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_track_album  ON track(album, album_artist);
CREATE INDEX IF NOT EXISTS idx_track_artist ON track(artist);
CREATE INDEX IF NOT EXISTS idx_track_added  ON track(added_at);

CREATE TABLE IF NOT EXISTS playlist (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    name       TEXT    NOT NULL,
    created_at INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS playlist_item (
    playlist_id INTEGER NOT NULL REFERENCES playlist(id) ON DELETE CASCADE,
    track_id    INTEGER NOT NULL REFERENCES track(id)    ON DELETE CASCADE,
    position    INTEGER NOT NULL,
    PRIMARY KEY (playlist_id, position)
);

CREATE INDEX IF NOT EXISTS idx_playlist_item_track ON playlist_item(track_id);

CREATE TABLE IF NOT EXISTS play_state (
    track_id       INTEGER PRIMARY KEY REFERENCES track(id) ON DELETE CASCADE,
    position_ms    INTEGER NOT NULL DEFAULT 0,
    play_count     INTEGER NOT NULL DEFAULT 0,
    last_played_at INTEGER NOT NULL DEFAULT 0
);

-- 上次的播放队列（整队接着放）。`play_state` 只管「某一首听到哪」，
-- 这份表管「当时听的是哪一整队、停在队列里的第几个」。
-- 曲目从曲库里被移出时，对应的行会级联删掉：队列自动变短，不会留下一个点不动的空洞。
CREATE TABLE IF NOT EXISTS play_queue (
    position   INTEGER PRIMARY KEY,
    track_id   INTEGER NOT NULL REFERENCES track(id) ON DELETE CASCADE,
    -- 上次停在谁身上（整表里最多一个 1）。用列而不是配置项：这一行跟着曲目一起删，
    -- 当前项就自动落到别的行上，不会指向一条已经不在的记录。
    is_current INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS scan_root (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    path    TEXT    NOT NULL UNIQUE,
    enabled INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
"#;

/// 索引数据库句柄。
///
/// 线程安全说明：`rusqlite::Connection` 是 `Send` 但不是 `Sync`，
/// 上层（FFI 层）负责用 `Mutex` 包住它，核心层保持最简。
pub struct Db {
    conn: Connection,
}

/// 扫描用的文件戳：只有 size + mtime 都相同才认为“没变过”。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FileStamp {
    pub size_bytes: u64,
    pub modified_at: i64,
}

impl std::fmt::Debug for Db {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Db").finish_non_exhaustive()
    }
}

impl Db {
    /// 打开磁盘数据库（开启 WAL，适合 Android 上的 app 私有目录）。
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let conn = Connection::open(path)?;
        let _ = conn.pragma_update(None, "journal_mode", "WAL");
        Self::from_connection(conn)
    }

    /// 内存库：单元测试与“预览扫描”用。
    pub fn open_in_memory() -> Result<Self> {
        Self::from_connection(Connection::open_in_memory()?)
    }

    fn from_connection(conn: Connection) -> Result<Self> {
        conn.pragma_update(None, "foreign_keys", "ON")?;
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        let db = Db { conn };
        db.migrate()?;
        Ok(db)
    }

    /// 建表 / 升级，并把结构版本写进 `meta.schema_version`。
    pub fn migrate(&self) -> Result<()> {
        self.conn.execute_batch(SCHEMA_SQL)?;
        self.migrate_in_library()?;
        self.conn.execute(
            "INSERT INTO meta(key, value) VALUES('schema_version', ?1)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![SCHEMA_VERSION.to_string()],
        )?;
        Ok(())
    }

    /// v1 → v2：补上 `track.in_library` 与它的索引。
    ///
    /// 老库里没有这个概念——那时候是“扫到什么就有什么”。升级时把已经打下的歌**全部
    /// 留下**（置 1）而不是清空：用户没要求删东西，而且界面上多的是办法一首首挑出去
    /// （长按、多选）。反过来，**新扫描到的文件**走列默认值 0，也就是不会自动进曲库，
    /// 这正是 `SCHEMA_SQL` 里那个 `DEFAULT 0` 的意义。
    ///
    /// 索引不能写在 `SCHEMA_SQL` 里：那个批次在建表之后立刻执行，而老库的表上还没有
    /// `in_library` 这一列（`CREATE TABLE IF NOT EXISTS` 不会改动已存在的表），
    /// 会直接报 “no such column”。所以它跟着列一起放在这里，两条路径都照顾到。
    fn migrate_in_library(&self) -> Result<()> {
        if !self.has_column("track", "in_library")? {
            self.conn.execute_batch(
                "ALTER TABLE track ADD COLUMN in_library INTEGER NOT NULL DEFAULT 0;
                 UPDATE track SET in_library = 1;",
            )?;
        }
        self.conn
            .execute_batch("CREATE INDEX IF NOT EXISTS idx_track_library ON track(in_library);")?;
        Ok(())
    }

    /// 表里有没有这一列（升级判定用）。
    ///
    /// `table` 只可能是本文件里的字面量、不是调用方输入，所以拼进 SQL 是安全的；
    /// 另外 `PRAGMA` 本来也不接受绑定参数。
    fn has_column(&self, table: &str, column: &str) -> Result<bool> {
        let mut stmt = self.conn.prepare(&format!("PRAGMA table_info({table})"))?;
        let mut rows = stmt.query([])?;
        while let Some(row) = rows.next()? {
            if row.get::<_, String>(1)? == column {
                return Ok(true);
            }
        }
        Ok(false)
    }
}

/// 当前 Unix 时间（秒）。
pub fn unix_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// 当前 Unix 时间（毫秒）。给 `play_state.last_played_at` 用。
///
/// 这里特意不用秒：换歌、退到后台、再点播放都可能在一秒之内连着写几次，
/// 秒级精度分不出先后，「继续播放」就会挑到错的那一首。
fn unix_now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

impl Db {
    /// 插入或按路径更新一首歌，返回其主键。
    ///
    /// 注意：`added_at` 在更新分支**刻意不覆盖**，保证“最近添加”排序不会因重扫而乱序。
    /// `in_library` 同理：**新插入的行默认不入库**（列默认值 0），重扫只更新标签与文件戳，
    /// 不会把用户已经挑出去（或还没收进来）的歌又塞回曲库。
    pub fn upsert_track(&self, track: &Track) -> Result<TrackId> {
        let added_at = if track.added_at > 0 {
            track.added_at
        } else {
            unix_now()
        };
        let id = self.conn.query_row(
            r#"
            INSERT INTO track (
                path, title, artist, album, album_artist, genre, year, track_no, disc_no,
                duration_ms, bitrate, sample_rate, channels, size_bytes, modified_at,
                has_cover, added_at
            ) VALUES (
                ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17
            )
            ON CONFLICT(path) DO UPDATE SET
                title        = excluded.title,
                artist       = excluded.artist,
                album        = excluded.album,
                album_artist = excluded.album_artist,
                genre        = excluded.genre,
                year         = excluded.year,
                track_no     = excluded.track_no,
                disc_no      = excluded.disc_no,
                duration_ms  = excluded.duration_ms,
                bitrate      = excluded.bitrate,
                sample_rate  = excluded.sample_rate,
                channels     = excluded.channels,
                size_bytes   = excluded.size_bytes,
                modified_at  = excluded.modified_at,
                has_cover    = excluded.has_cover
            RETURNING id
            "#,
            params![
                track.path,
                track.title,
                track.artist,
                track.album,
                track.album_artist,
                track.genre,
                track.year.map(|v| v as i64),
                track.track_no.map(|v| v as i64),
                track.disc_no.map(|v| v as i64),
                track.duration_ms as i64,
                track.bitrate.map(|v| v as i64),
                track.sample_rate.map(|v| v as i64),
                track.channels.map(|v| v as i64),
                track.size_bytes as i64,
                track.modified_at,
                i64::from(track.has_cover),
                added_at,
            ],
            |row| row.get(0),
        )?;
        Ok(id)
    }

    pub fn track_by_path(&self, path: &str) -> Result<Option<Track>> {
        let sql = format!("SELECT {TRACK_COLUMNS} FROM track WHERE path = ?1");
        Ok(self
            .conn
            .query_row(&sql, params![path], map_track)
            .optional()?)
    }

    pub fn track_by_id(&self, id: TrackId) -> Result<Option<Track>> {
        let sql = format!("SELECT {TRACK_COLUMNS} FROM track WHERE id = ?1");
        Ok(self
            .conn
            .query_row(&sql, params![id], map_track)
            .optional()?)
    }

    /// 全库的 `路径 → 文件戳` 映射，供增量扫描做差异对比。
    pub fn known_files(&self) -> Result<HashMap<String, FileStamp>> {
        let mut stmt = self
            .conn
            .prepare("SELECT path, size_bytes, modified_at FROM track")?;
        let rows = stmt.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                FileStamp {
                    size_bytes: row.get::<_, i64>(1)?.max(0) as u64,
                    modified_at: row.get(2)?,
                },
            ))
        })?;

        let mut map = HashMap::new();
        for row in rows {
            let (path, stamp) = row?;
            map.insert(path, stamp);
        }
        Ok(map)
    }

    /// 某个根目录下的所有已入库路径（用于清理已消失的文件）。
    pub fn paths_under_root(&self, root: &str) -> Result<Vec<String>> {
        // 用 `root/` 前缀匹配，避免 `/sdcard/music2` 被 `/sdcard/music` 误伤。
        let prefix = format!("{}/", root.trim_end_matches('/'));
        let mut stmt = self
            .conn
            .prepare("SELECT path FROM track WHERE path LIKE ?1 || '%'")?;
        let rows = stmt.query_map(params![prefix], |row| row.get::<_, String>(0))?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    /// 按路径列表删除，返回实际删除的行数。
    pub fn delete_paths(&self, paths: &[String]) -> Result<usize> {
        if paths.is_empty() {
            return Ok(0);
        }
        let tx = self.conn.unchecked_transaction()?;
        let mut removed = 0usize;
        {
            let mut stmt = tx.prepare("DELETE FROM track WHERE path = ?1")?;
            for path in paths {
                removed += stmt.execute(params![path])?;
            }
        }
        tx.commit()?;
        Ok(removed)
    }
}
impl Db {
    /// 全库列表（**含未入库的歌**），支持白名单排序与可选条数限制（`None` = 不限）。
    pub fn all_tracks(
        &self,
        key: SortKey,
        order: SortOrder,
        limit: Option<u32>,
    ) -> Result<Vec<Track>> {
        self.tracks_where(Scope::All, key, order, limit)
    }

    /// **曲库**里的歌（`in_library = 1`）：主页与「我的音乐」看的就是这一份。
    pub fn library_tracks(
        &self,
        key: SortKey,
        order: SortOrder,
        limit: Option<u32>,
    ) -> Result<Vec<Track>> {
        self.tracks_where(Scope::Library, key, order, limit)
    }

    /// 建了索引、但**不在曲库**里的歌：扫描发现的新文件，以及被用户从曲库移出的那些。
    /// 界面上的「＋ 添加歌曲」列的正是这一份。
    pub fn pending_tracks(&self, limit: Option<u32>) -> Result<Vec<Track>> {
        let sql = format!(
            "SELECT {TRACK_COLUMNS} FROM track
             WHERE in_library = 0
             ORDER BY title COLLATE NOCASE ASC, path ASC
             LIMIT ?1"
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let rows = stmt.query_map(params![limit.map(i64::from).unwrap_or(-1)], map_track)?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    /// 把若干首歌收进 / 移出曲库，返回真正改变了的行数。
    ///
    /// 移出只是把这个标记清掉（**索引记录与文件都留着**），所以还能在「＋ 添加歌曲」
    /// 里原样找回来；要连着文件一起处理是 [`Db::delete_paths`] 那边的事。
    pub fn set_in_library(&self, ids: &[TrackId], in_library: bool) -> Result<usize> {
        if ids.is_empty() {
            return Ok(0);
        }
        let flag = i64::from(in_library);
        let tx = self.conn.unchecked_transaction()?;
        let mut changed = 0usize;
        {
            let mut stmt =
                tx.prepare("UPDATE track SET in_library = ?2 WHERE id = ?1 AND in_library <> ?2")?;
            for id in ids {
                changed += stmt.execute(params![id, flag])?;
            }
        }
        tx.commit()?;
        Ok(changed)
    }

    /// [`Db::all_tracks`] 与 [`Db::library_tracks`] 的公共实现。
    fn tracks_where(
        &self,
        scope: Scope,
        key: SortKey,
        order: SortOrder,
        limit: Option<u32>,
    ) -> Result<Vec<Track>> {
        let sql = format!(
            "SELECT {TRACK_COLUMNS} FROM track WHERE {} ORDER BY {} LIMIT ?1",
            scope.sql(),
            order_by(key, order)
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let rows = stmt.query_map(params![limit.map(i64::from).unwrap_or(-1)], map_track)?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    /// 按给定的 id 顺序取出歌曲（播放队列恢复用）。
    pub fn tracks_by_ids(&self, ids: &[TrackId]) -> Result<Vec<Track>> {
        let mut out = Vec::with_capacity(ids.len());
        for id in ids {
            if let Some(track) = self.track_by_id(*id)? {
                out.push(track);
            }
        }
        Ok(out)
    }

    /// 模糊搜索标题 / 艺术家 / 专辑。
    ///
    /// `scope` 决定搜哪儿。界面上的搜索框过滤的是**曲库列表**，所以传
    /// [`Scope::Library`]：搜出没入库的歌只会让人以为它已经在曲库里了。
    pub fn search(&self, query: &str, limit: u32, scope: Scope) -> Result<Vec<Track>> {
        let pattern = like_pattern(query);
        let sql = format!(
            "SELECT {TRACK_COLUMNS} FROM track
             WHERE {} AND (
                    title LIKE ?1 ESCAPE '\\'
                 OR artist LIKE ?1 ESCAPE '\\'
                 OR album  LIKE ?1 ESCAPE '\\'
                 OR album_artist LIKE ?1 ESCAPE '\\')
             ORDER BY title COLLATE NOCASE ASC
             LIMIT ?2",
            scope.sql()
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let rows = stmt.query_map(params![pattern, i64::from(limit)], map_track)?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    /// 专辑聚合：按 (专辑名, 专辑艺术家) 分组。
    pub fn albums(&self) -> Result<Vec<Album>> {
        let mut stmt = self.conn.prepare(
            r#"
            SELECT TRIM(album) AS album_name,
                   COALESCE(
                       NULLIF(TRIM(COALESCE(album_artist, '')), ''),
                       NULLIF(TRIM(COALESCE(artist, '')), ''),
                       '未知艺术家'
                   ) AS artist_name,
                   COUNT(*)                  AS track_count,
                   COALESCE(SUM(duration_ms), 0) AS total_duration,
                   MAX(year)                 AS year,
                   MAX(has_cover)            AS has_cover
            FROM track
            WHERE album IS NOT NULL AND TRIM(album) <> ''
            GROUP BY album_name, artist_name
            ORDER BY album_name COLLATE NOCASE ASC, artist_name ASC
            "#,
        )?;
        let rows = stmt.query_map([], |row| {
            Ok(Album {
                name: row.get(0)?,
                album_artist: row.get(1)?,
                track_count: row.get::<_, i64>(2)?.max(0) as u32,
                duration_ms: row.get::<_, i64>(3)?.max(0) as u64,
                year: opt_u32(row.get(4)?),
                has_cover: row.get::<_, i64>(5)? != 0,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    /// 艺术家聚合。
    pub fn artists(&self) -> Result<Vec<Artist>> {
        let mut stmt = self.conn.prepare(
            r#"
            SELECT COALESCE(NULLIF(TRIM(COALESCE(artist, '')), ''), '未知艺术家') AS artist_name,
                   COUNT(*) AS track_count,
                   COUNT(DISTINCT CASE
                       WHEN album IS NULL OR TRIM(album) = '' THEN NULL
                       ELSE TRIM(album) || '|' ||
                            COALESCE(NULLIF(TRIM(COALESCE(album_artist, '')), ''),
                                     NULLIF(TRIM(COALESCE(artist, '')), ''), '')
                   END) AS album_count
            FROM track
            GROUP BY artist_name
            ORDER BY artist_name COLLATE NOCASE ASC
            "#,
        )?;
        let rows = stmt.query_map([], |row| {
            Ok(Artist {
                name: row.get(0)?,
                track_count: row.get::<_, i64>(1)?.max(0) as u32,
                album_count: row.get::<_, i64>(2)?.max(0) as u32,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    /// 整份索引的统计（**含未入库的歌**）。
    pub fn stats(&self) -> Result<Stats> {
        self.stats_where(Scope::All)
    }

    /// **曲库**的统计；主页底部那行「452 / 27:27:36 / 9.75 GB」用它。
    pub fn library_stats(&self) -> Result<Stats> {
        self.stats_where(Scope::Library)
    }

    /// [`Db::stats`] 与 [`Db::library_stats`] 的公共实现。
    fn stats_where(&self, scope: Scope) -> Result<Stats> {
        let scope_where = format!("WHERE {}", scope.sql());
        let (track_count, total_duration_ms, total_size_bytes) = self.conn.query_row(
            &format!(
                "SELECT COUNT(*), COALESCE(SUM(duration_ms), 0), COALESCE(SUM(size_bytes), 0)
                 FROM track {scope_where}"
            ),
            [],
            |row| {
                Ok((
                    row.get::<_, i64>(0)?.max(0) as u32,
                    row.get::<_, i64>(1)?.max(0) as u64,
                    row.get::<_, i64>(2)?.max(0) as u64,
                ))
            },
        )?;

        let album_count: i64 = self.conn.query_row(
            &format!(
                "SELECT COUNT(*) FROM (
                     SELECT 1 FROM track {scope_where}
                       AND album IS NOT NULL AND TRIM(album) <> ''
                     GROUP BY TRIM(album), COALESCE(TRIM(album_artist), TRIM(artist), '')
                 )"
            ),
            [],
            |row| row.get(0),
        )?;

        let artist_count: i64 = self.conn.query_row(
            &format!(
                "SELECT COUNT(*) FROM (
                     SELECT 1 FROM track {scope_where}
                     GROUP BY COALESCE(NULLIF(TRIM(COALESCE(artist, '')), ''), '未知艺术家')
                 )"
            ),
            [],
            |row| row.get(0),
        )?;

        let playlist_count: i64 =
            self.conn
                .query_row("SELECT COUNT(*) FROM playlist", [], |row| row.get(0))?;

        Ok(Stats {
            track_count,
            album_count: album_count.max(0) as u32,
            artist_count: artist_count.max(0) as u32,
            playlist_count: playlist_count.max(0) as u32,
            total_duration_ms,
            total_size_bytes,
        })
    }
}

impl Db {
    /// 新建播放列表，返回其 id。
    pub fn create_playlist(&self, name: &str) -> Result<PlaylistId> {
        let trimmed = name.trim();
        let trimmed = if trimmed.is_empty() {
            "新建列表"
        } else {
            trimmed
        };
        let id = self.conn.query_row(
            "INSERT INTO playlist(name, created_at) VALUES(?1, ?2) RETURNING id",
            params![trimmed, unix_now()],
            |row| row.get(0),
        )?;
        Ok(id)
    }

    pub fn playlists(&self) -> Result<Vec<Playlist>> {
        let mut stmt = self.conn.prepare(
            "SELECT p.id, p.name, p.created_at,
                    (SELECT COUNT(*) FROM playlist_item i WHERE i.playlist_id = p.id)
             FROM playlist p
             ORDER BY p.name COLLATE NOCASE ASC",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok(Playlist {
                id: row.get(0)?,
                name: row.get(1)?,
                created_at: row.get(2)?,
                track_count: row.get::<_, i64>(3)?.max(0) as u32,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    /// 一个播放列表（`None` = 这个 id 已经不存在了）。
    ///
    /// 导出要用它拿名字与条目数；界面那边只需要 [`Db::playlists`] 那一整份。
    pub fn playlist_by_id(&self, playlist: PlaylistId) -> Result<Option<Playlist>> {
        let found = self
            .conn
            .query_row(
                "SELECT p.id, p.name, p.created_at,
                        (SELECT COUNT(*) FROM playlist_item i WHERE i.playlist_id = p.id)
                 FROM playlist p WHERE p.id = ?1",
                params![playlist],
                |row| {
                    Ok(Playlist {
                        id: row.get(0)?,
                        name: row.get(1)?,
                        created_at: row.get(2)?,
                        track_count: row.get::<_, i64>(3)?.max(0) as u32,
                    })
                },
            )
            .optional()?;
        Ok(found)
    }

    pub fn rename_playlist(&self, playlist: PlaylistId, name: &str) -> Result<()> {
        self.conn.execute(
            "UPDATE playlist SET name = ?2 WHERE id = ?1",
            params![playlist, name.trim()],
        )?;
        Ok(())
    }

    pub fn delete_playlist(&self, playlist: PlaylistId) -> Result<()> {
        self.conn
            .execute("DELETE FROM playlist WHERE id = ?1", params![playlist])?;
        Ok(())
    }

    /// 追加到播放列表末尾。重复添加会被忽略（同一列表内不重复）。
    pub fn add_to_playlist(&self, playlist: PlaylistId, track: TrackId) -> Result<bool> {
        let exists: Option<i64> = self
            .conn
            .query_row(
                "SELECT 1 FROM playlist_item WHERE playlist_id = ?1 AND track_id = ?2 LIMIT 1",
                params![playlist, track],
                |row| row.get(0),
            )
            .optional()?;
        if exists.is_some() {
            return Ok(false);
        }
        let next: i64 = self.conn.query_row(
            "SELECT COALESCE(MAX(position), -1) + 1 FROM playlist_item WHERE playlist_id = ?1",
            params![playlist],
            |row| row.get(0),
        )?;
        self.conn.execute(
            "INSERT INTO playlist_item(playlist_id, track_id, position) VALUES(?1, ?2, ?3)",
            params![playlist, track, next],
        )?;
        Ok(true)
    }

    /// 按位置移除，并把这个位置之后的条目整体前移，保持 position 连续。
    pub fn remove_from_playlist(&self, playlist: PlaylistId, position: i64) -> Result<()> {
        let tx = self.conn.unchecked_transaction()?;
        tx.execute(
            "DELETE FROM playlist_item WHERE playlist_id = ?1 AND position = ?2",
            params![playlist, position],
        )?;
        tx.execute(
            "UPDATE playlist_item SET position = position - 1
             WHERE playlist_id = ?1 AND position > ?2",
            params![playlist, position],
        )?;
        tx.commit()?;
        Ok(())
    }

    /// 按**曲目 id** 从播放列表里移除，返回是否真的删掉了。
    ///
    /// 界面上点的是「某一行那一首歌」，而下标（position）会在曲目被重扫移除时留下空洞
    /// （`playlist_item` 是 `ON DELETE CASCADE`），所以这里不收下标，收 id。
    /// 删完顺手把 position 重新编号成连续的 `0..n-1`：这样「下标就是 position」
    /// 这个前提在 [`Db::remove_from_playlist`] 那边也继续成立。
    pub fn remove_track_from_playlist(&self, playlist: PlaylistId, track: TrackId) -> Result<bool> {
        let tx = self.conn.unchecked_transaction()?;
        let removed = tx.execute(
            "DELETE FROM playlist_item WHERE playlist_id = ?1 AND track_id = ?2",
            params![playlist, track],
        )?;
        if removed > 0 {
            compact_playlist(&tx, playlist)?;
        }
        tx.commit()?;
        Ok(removed > 0)
    }

    pub fn playlist_tracks(&self, playlist: PlaylistId) -> Result<Vec<Track>> {
        let sql = format!(
            "SELECT {} FROM track t
             JOIN playlist_item i ON i.track_id = t.id
             WHERE i.playlist_id = ?1
             ORDER BY i.position ASC",
            TRACK_COLUMNS
                .split(", ")
                .map(|c| format!("t.{}", c.trim()))
                .collect::<Vec<_>>()
                .join(", ")
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let rows = stmt.query_map(params![playlist], map_track)?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    /// 用一份**从文件里读出来的条目**新建一个列表，返回导入结果。
    ///
    /// 规矩：
    /// - 条目**按文件里的顺序**落库（列表顺序就是播放顺序，打乱了等于毁掉用户的排序）；
    /// - 同一首歌在文件里出现多次只收第一次（`playlist_item` 不允许同一列表里重复）；
    /// - 对不上索引的条目只计数、不报错（见 [`PlaylistImport`]）。**不替用户建记录**：
    ///   索引里没有就意味着这个文件从没被扫到过，那是「扫描」该干的事，
    ///   在这里顺手塞一条 `track` 记录，只会让曲库出现一堆没读全标签的行。
    pub fn import_playlist(&self, name: &str, entries: &[String]) -> Result<PlaylistImport> {
        let index = self.path_index()?;
        // 建列表也放进事务里：中途写失败时不会留下一个半截的空列表。
        let tx = self.conn.unchecked_transaction()?;
        let playlist = self.create_playlist(name)?;

        let mut added = 0u32;
        let mut seen: std::collections::HashSet<TrackId> = std::collections::HashSet::new();
        let mut missing: Vec<String> = Vec::new();

        // 一个事务写完：一份列表可能上百条，逐条自动提交在真机上要几百次 fsync。
        let mut position: i64 = 0;
        for entry in entries {
            let Some(track) = index.resolve(entry) else {
                missing.push(entry.clone());
                continue;
            };
            if !seen.insert(track) {
                continue;
            }
            tx.execute(
                "INSERT INTO playlist_item(playlist_id, track_id, position) VALUES(?1, ?2, ?3)",
                params![playlist, track, position],
            )?;
            position += 1;
            added += 1;
        }
        tx.commit()?;

        Ok(PlaylistImport {
            playlist_id: playlist,
            added,
            missing: missing.len() as u32,
            missing_paths: missing.into_iter().take(MISSING_PREVIEW_LIMIT).collect(),
            // 网络条目在解析那一步就被剔掉了，这里没法知道有几条（见 `PlaylistImport`）。
            skipped: 0,
        })
    }

    /// 全部曲目的「路径 → id」索引，导入播放列表时用来把条目对到曲目上。
    ///
    /// 只取这两列：曲库几千上万首时，把整行元数据都读出来纯属浪费。
    /// 包含**没进曲库**的曲目（`in_library = 0`）：那份文件在磁盘上就是存在的，
    /// 列表里有它很正常（曲库只是「用户挑出来的那些」）。
    fn path_index(&self) -> Result<PathIndex> {
        let mut stmt = self.conn.prepare("SELECT path, id FROM track")?;
        let rows = stmt.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, TrackId>(1)?))
        })?;
        Ok(PathIndex::new(rows.collect::<rusqlite::Result<Vec<_>>>()?))
    }
}

/// 把某个列表里的 position 重新编号成连续的 `0..n-1`（保持现有顺序）。
///
/// 只可能「变小」，而且是按升序逐行写入，所以中途不会撞上
/// `playlist_item` 的 `PRIMARY KEY(playlist_id, position)`。
fn compact_playlist(conn: &Connection, playlist: PlaylistId) -> Result<()> {
    let rowids: Vec<i64> = {
        let mut stmt = conn.prepare(
            "SELECT rowid FROM playlist_item
             WHERE playlist_id = ?1 ORDER BY position ASC, rowid ASC",
        )?;
        let rows = stmt.query_map(params![playlist], |row| row.get::<_, i64>(0))?;
        rows.collect::<rusqlite::Result<Vec<_>>>()?
    };
    let mut stmt = conn
        .prepare("UPDATE playlist_item SET position = ?3 WHERE playlist_id = ?1 AND rowid = ?2")?;
    for (index, rowid) in rowids.iter().enumerate() {
        stmt.execute(params![playlist, rowid, index as i64])?;
    }
    Ok(())
}

impl Db {
    /// 保存播放进度（0 表示从头开始，不做特殊处理）。
    ///
    /// 同时刷新 `last_played_at`：这一行记的就是「最近在放什么、放到哪」，
    /// [`Db::resume_point`] 靠它找出下次该接着放的那一首。
    /// 播放次数是另一件事，由 [`Db::mark_played`] 管。
    pub fn save_position(&self, track: TrackId, position_ms: u64) -> Result<()> {
        self.conn.execute(
            "INSERT INTO play_state(track_id, position_ms, last_played_at) VALUES(?1, ?2, ?3)
             ON CONFLICT(track_id) DO UPDATE SET
                 position_ms    = excluded.position_ms,
                 last_played_at = excluded.last_played_at",
            params![track, position_ms as i64, unix_now_ms()],
        )?;
        Ok(())
    }

    /// 补一个时长（只在曲库里记的是 0 时写），返回是否真的写了。
    ///
    /// 为什么需要它：时长来自标签/容器解析，而有些文件解析不出来却照样能播
    /// ——真机上遇到过「从 mp4 里扒出来、文件名叫 `.mp3`」的那种：
    /// 解码器明明知道它是 336 秒，标签里却是 0，列表里就永远显示 `--:--`。
    /// 播放时顺手把它补上，下次扫描也会带着这个值走（大小/时间没变则不会覆盖）。
    pub fn fill_duration(&self, track: TrackId, duration_ms: u64) -> Result<bool> {
        if duration_ms == 0 {
            return Ok(false);
        }
        let changed = self.conn.execute(
            "UPDATE track SET duration_ms = ?2 WHERE id = ?1 AND duration_ms = 0",
            params![track, duration_ms as i64],
        )?;
        Ok(changed > 0)
    }

    /// 「继续播放」：最近动过进度的那一首，以及当时的位置。
    ///
    /// 从来没记录过进度时返回 `None`。曲目被重扫移出曲库时对应的行会级联删掉，
    /// 所以这里也不会给出一个已经不存在的文件——那种“接着放”一启动就会报错。
    pub fn resume_point(&self) -> Result<Option<ResumePoint>> {
        let latest: Option<(TrackId, u64)> = self
            .conn
            .query_row(
                "SELECT track_id, position_ms FROM play_state
                 WHERE last_played_at > 0
                 ORDER BY last_played_at DESC
                 LIMIT 1",
                [],
                |row| Ok((row.get(0)?, row.get::<_, i64>(1)?.max(0) as u64)),
            )
            .optional()?;
        let Some((track_id, position_ms)) = latest else {
            return Ok(None);
        };
        // 曲目与进度分开查：`play_state` 里没有曲目信息，而 `track` 的列是
        // 一处定义、多处复用（见 `TRACK_COLUMNS`），拼进去反而容易和 map_track 错位。
        Ok(self
            .track_by_id(track_id)?
            .map(|track| ResumePoint { track, position_ms }))
    }

    /// 记下整份播放队列与当前项（下次启动整队接着放，而不是只剩一首）。
    ///
    /// `index` 越界时夹到合法范围里：调用方拿的是引擎快照的下标，偶尔会慢半拍，
    /// 与其为这个拒绝保存整份队列，不如按最后一首算。
    ///
    /// 空队列会把这份快照清掉——没队可放时，「上一队」也不该被记着。
    pub fn save_queue(&self, track_ids: &[TrackId], index: usize) -> Result<()> {
        let tx = self.conn.unchecked_transaction()?;
        // 整表重写：队列通常几十上百项，比逐行 diff 简单得多，而且在一个事务里。
        // 某首曲子刚好被删掉时外键会报错，事务随即回滚——旧快照原样留着，不会写坏。
        tx.execute("DELETE FROM play_queue", [])?;
        if !track_ids.is_empty() {
            let current = index.min(track_ids.len() - 1);
            let mut stmt = tx.prepare(
                "INSERT INTO play_queue(position, track_id, is_current) VALUES(?1, ?2, ?3)",
            )?;
            for (position, id) in track_ids.iter().enumerate() {
                stmt.execute(params![position as i64, id, (position == current) as i64])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    /// 上次的播放队列（整队接着放）；从没记过队列时返回 `None`。
    ///
    /// 进度从 `play_state` 现取，不在这份快照里另存一份：那边每两秒就会被刷新，
    /// 是更新鲜的那一份（在这里再存一遍只会多一个会走偏的副本）。
    pub fn resume_queue(&self) -> Result<Option<ResumeQueue>> {
        let rows: Vec<(TrackId, bool, String)> = {
            // 内连接：曲目已经从库里消失的行直接不出现（外键通常也会把它们删掉了，
            // 但老库、手改过的库未必有外键约束，这里不指望它）。
            let mut stmt = self.conn.prepare(
                "SELECT q.track_id, q.is_current, t.path
                 FROM play_queue q
                 JOIN track t ON t.id = q.track_id
                 ORDER BY q.position ASC",
            )?;
            let rows = stmt.query_map([], |row| {
                Ok((row.get(0)?, row.get::<_, i64>(1)? != 0, row.get(2)?))
            })?;
            rows.collect::<rusqlite::Result<Vec<_>>>()?
        };
        if rows.is_empty() {
            return Ok(None);
        }

        // 下标按实际剩下的条目重数：中间少了谁都不影响「上次那一首」是谁，
        // 而这是整队接着放唯一必须对准的东西。
        let mut entries = Vec::with_capacity(rows.len());
        let mut index = 0usize;
        for (id, is_current, path) in rows {
            if is_current {
                index = entries.len();
            }
            entries.push(QueueTrack { id, path });
        }
        let position_ms = self
            .play_state(entries[index].id)?
            .map(|state| state.position_ms)
            .unwrap_or(0);
        Ok(Some(ResumeQueue {
            entries,
            index: index as u32,
            position_ms,
        }))
    }

    /// 记下「随机播放 / 循环模式」这两项设置（退出应用时写一次，下次启动照旧）。
    ///
    /// 存 `meta` 而不是新表：它们是**单值设置**，没有「一行对应一首歌」这种概念，
    /// 为两张只存一行一列的表再写一套增删改查反而更难读。
    ///
    /// 两条在同一个事务里写：它们总是一起变，分开写有可能只落下半份。
    pub fn save_playback_mode(&self, shuffle: bool, repeat_code: u8) -> Result<()> {
        let tx = self.conn.unchecked_transaction()?;
        tx.execute(
            "INSERT INTO meta(key, value) VALUES(?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params!["play_shuffle", if shuffle { "1" } else { "0" }],
        )?;
        tx.execute(
            "INSERT INTO meta(key, value) VALUES(?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params!["play_repeat", repeat_code.to_string()],
        )?;
        tx.commit()?;
        Ok(())
    }

    /// 上次的「随机播放 / 循环模式」；从没记过时返回 `None`（调用方按默认值来）。
    ///
    /// **两项都记过才算数**：只落了半份说明这份记录是坏的（手改过的库、写了一半），
    /// 与其猜一半，不如整体当没记过——反正这两项用户随时能改。
    ///
    /// `repeat_code` 是播放层的编码（0 关 / 1 列表 / 2 单曲），定义在
    /// `musicplayer_audio::RepeatMode::code()`：core 这一层不认识播放层的类型，
    /// 存一个编码就够，为它引入依赖不值得。
    pub fn playback_mode(&self) -> Result<Option<(bool, u8)>> {
        let saved = self.conn.query_row(
            "SELECT (SELECT value FROM meta WHERE key = 'play_shuffle'),
                    (SELECT value FROM meta WHERE key = 'play_repeat')",
            [],
            |row| {
                Ok((
                    row.get::<_, Option<String>>(0)?,
                    row.get::<_, Option<String>>(1)?,
                ))
            },
        )?;
        match saved {
            (Some(shuffle), Some(repeat)) => Ok(Some((
                shuffle == "1",
                // 认不出来的值交给播放层兜底（它那边 `from_code` 会当成「关」），
                // 这里只负责把字符串变成数字。
                repeat.parse::<u8>().unwrap_or(0),
            ))),
            _ => Ok(None),
        }
    }

    pub fn play_state(&self, track: TrackId) -> Result<Option<PlayState>> {
        Ok(self
            .conn
            .query_row(
                "SELECT track_id, position_ms, play_count, last_played_at
                 FROM play_state WHERE track_id = ?1",
                params![track],
                |row| {
                    Ok(PlayState {
                        track_id: row.get(0)?,
                        position_ms: row.get::<_, i64>(1)?.max(0) as u64,
                        play_count: row.get::<_, i64>(2)?.max(0) as u32,
                        last_played_at: row.get(3)?,
                    })
                },
            )
            .optional()?)
    }

    /// 记一次播放：计数 +1，并刷新时间戳（进度由 `save_position` 单独维护）。
    ///
    /// 时间戳与 [`Db::save_position`] 同一单位（Unix 毫秒），两者可以混着排序。
    pub fn mark_played(&self, track: TrackId) -> Result<()> {
        self.conn.execute(
            "INSERT INTO play_state(track_id, play_count, last_played_at) VALUES(?1, 1, ?2)
             ON CONFLICT(track_id) DO UPDATE SET
                 play_count     = play_count + 1,
                 last_played_at = excluded.last_played_at",
            params![track, unix_now_ms()],
        )?;
        Ok(())
    }

    /// 最近播放（按时间倒序）。
    pub fn recently_played(&self, limit: u32) -> Result<Vec<Track>> {
        let sql = format!(
            "SELECT {} FROM track t
             JOIN play_state s ON s.track_id = t.id
             WHERE s.play_count > 0
             ORDER BY s.last_played_at DESC
             LIMIT ?1",
            TRACK_COLUMNS
                .split(", ")
                .map(|c| format!("t.{}", c.trim()))
                .collect::<Vec<_>>()
                .join(", ")
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let rows = stmt.query_map(params![i64::from(limit)], map_track)?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    /// 登记一个扫描根目录（Android 上就是用户通过 SAF/媒体权限授权后的目录）。
    pub fn add_scan_root(&self, path: &str) -> Result<()> {
        self.conn.execute(
            "INSERT INTO scan_root(path) VALUES(?1) ON CONFLICT(path) DO UPDATE SET enabled = 1",
            params![path.trim_end_matches('/')],
        )?;
        Ok(())
    }

    pub fn remove_scan_root(&self, path: &str) -> Result<()> {
        self.conn.execute(
            "DELETE FROM scan_root WHERE path = ?1",
            params![path.trim_end_matches('/')],
        )?;
        Ok(())
    }

    pub fn scan_roots(&self) -> Result<Vec<String>> {
        let mut stmt = self
            .conn
            .prepare("SELECT path FROM scan_root WHERE enabled = 1 ORDER BY path ASC")?;
        let rows = stmt.query_map([], |row| row.get::<_, String>(0))?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }
}

/// 把用户输入变成安全的 LIKE 模式：转义 `\`、`%`、`_`，配合 `ESCAPE '\'` 使用。
fn like_pattern(query: &str) -> String {
    let mut escaped = String::with_capacity(query.len() + 2);
    escaped.push('%');
    for ch in query.chars() {
        if matches!(ch, '\\' | '%' | '_') {
            escaped.push('\\');
        }
        escaped.push(ch);
    }
    escaped.push('%');
    escaped
}

/// 查询范围：整份索引，还是只有曲库里的那些。
///
/// [`Scope::sql`] 返回的全是本文件里的字面量、不含调用方输入，所以拼进 SQL 是安全的
/// ——和 `order_by` 的白名单是同一个道理。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scope {
    /// 建过索引的都在内（含未入库的）。
    All,
    /// 只有 `in_library = 1` 的那些，也就是界面上说的「曲库」。
    Library,
}

impl Scope {
    fn sql(self) -> &'static str {
        match self {
            Scope::All => "1",
            Scope::Library => "in_library = 1",
        }
    }
}

fn order_by(key: SortKey, order: SortOrder) -> &'static str {
    // 白名单映射，杜绝把调用方输入拼进 SQL。
    match (key, order) {
        (SortKey::Title, SortOrder::Ascending) => "title COLLATE NOCASE ASC, path ASC",
        (SortKey::Title, SortOrder::Descending) => "title COLLATE NOCASE DESC, path ASC",
        (SortKey::Artist, SortOrder::Ascending) => "artist IS NULL, artist COLLATE NOCASE ASC",
        (SortKey::Artist, SortOrder::Descending) => "artist IS NULL, artist COLLATE NOCASE DESC",
        (SortKey::Album, SortOrder::Ascending) => {
            "album IS NULL, album COLLATE NOCASE ASC, disc_no, track_no, path"
        }
        (SortKey::Album, SortOrder::Descending) => {
            "album IS NULL, album COLLATE NOCASE DESC, disc_no, track_no, path"
        }
        (SortKey::AddedAt, SortOrder::Ascending) => "added_at ASC, id ASC",
        (SortKey::AddedAt, SortOrder::Descending) => "added_at DESC, id DESC",
        (SortKey::Duration, SortOrder::Ascending) => "duration_ms ASC, path ASC",
        (SortKey::Duration, SortOrder::Descending) => "duration_ms DESC, path ASC",
        (SortKey::Path, SortOrder::Ascending) => "path ASC",
        (SortKey::Path, SortOrder::Descending) => "path DESC",
    }
}

fn map_track(row: &Row<'_>) -> rusqlite::Result<Track> {
    Ok(Track {
        id: row.get(0)?,
        path: row.get(1)?,
        title: row.get(2)?,
        artist: row.get(3)?,
        album: row.get(4)?,
        album_artist: row.get(5)?,
        genre: row.get(6)?,
        year: opt_u32(row.get(7)?),
        track_no: opt_u32(row.get(8)?),
        disc_no: opt_u32(row.get(9)?),
        duration_ms: row.get::<_, i64>(10)?.max(0) as u64,
        bitrate: opt_u32(row.get(11)?),
        sample_rate: opt_u32(row.get(12)?),
        channels: opt_u32(row.get(13)?).map(|v| v as u8),
        size_bytes: row.get::<_, i64>(14)?.max(0) as u64,
        modified_at: row.get(15)?,
        has_cover: row.get::<_, i64>(16)? != 0,
        added_at: row.get(17)?,
    })
}

fn opt_u32(value: Option<i64>) -> Option<u32> {
    value.filter(|v| *v >= 0).map(|v| v as u32)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{SortKey, SortOrder};

    /// 退出时记下的随机 / 循环设置，下次启动要能原样读回来。
    #[test]
    fn playback_mode_round_trip() {
        let db = Db::open_in_memory().expect("内存库");
        assert_eq!(db.playback_mode().expect("读设置"), None, "从没记过");

        db.save_playback_mode(true, 2).expect("记设置");
        assert_eq!(db.playback_mode().expect("读设置"), Some((true, 2)));

        db.save_playback_mode(false, 1).expect("再记一次");
        assert_eq!(db.playback_mode().expect("读设置"), Some((false, 1)));
    }

    /// 只落了半份（写了一半、手改过的库）时整体当没记过。
    ///
    /// 两项是一起写进去的，缺一条就不是我们写的那份记录：与其猜一半，
    /// 不如整体回到默认——反正这两项用户随时能改。
    #[test]
    fn incomplete_playback_mode_is_ignored() {
        let db = Db::open_in_memory().expect("内存库");
        db.conn
            .execute(
                "INSERT INTO meta(key, value) VALUES('play_shuffle', '1')",
                [],
            )
            .expect("手写半份");
        assert_eq!(db.playback_mode().expect("读设置"), None);
    }

    fn sample(path: &str, title: &str, artist: &str, album: &str, duration_ms: u64) -> Track {
        Track {
            path: path.to_string(),
            title: title.to_string(),
            artist: Some(artist.to_string()),
            album: Some(album.to_string()),
            album_artist: Some(artist.to_string()),
            duration_ms,
            ..Default::default()
        }
    }

    fn memory_db() -> Db {
        Db::open_in_memory().expect("in-memory db")
    }

    #[test]
    fn schema_version_is_recorded() {
        let db = memory_db();
        let version: String = db
            .conn
            .query_row(
                "SELECT value FROM meta WHERE key = 'schema_version'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(version, SCHEMA_VERSION.to_string());
    }

    #[test]
    fn upsert_is_idempotent_by_path() {
        let db = memory_db();
        let first = db
            .upsert_track(&sample("/m/a.mp3", "Old", "A", "Al", 1000))
            .unwrap();

        let mut updated = sample("/m/a.mp3", "New", "A", "Al", 2000);
        updated.year = Some(1999);
        let second = db.upsert_track(&updated).unwrap();

        assert_eq!(first, second, "同一路径必须复用同一行");
        let stored = db.track_by_path("/m/a.mp3").unwrap().unwrap();
        assert_eq!(stored.title, "New");
        assert_eq!(stored.duration_ms, 2000);
        assert_eq!(stored.year, Some(1999));
        assert_eq!(db.stats().unwrap().track_count, 1);
    }

    #[test]
    fn upsert_preserves_original_added_at() {
        let db = memory_db();
        let mut track = sample("/m/a.mp3", "T", "A", "Al", 1000);
        track.added_at = 12345;
        db.upsert_track(&track).unwrap();

        // 重扫时调用方不会传 added_at，旧值必须被保留。
        let mut rescanned = sample("/m/a.mp3", "T", "A", "Al", 1000);
        rescanned.added_at = 0;
        db.upsert_track(&rescanned).unwrap();

        let stored = db.track_by_path("/m/a.mp3").unwrap().unwrap();
        assert_eq!(stored.added_at, 12345);
    }

    #[test]
    fn known_files_reports_size_and_mtime() {
        let db = memory_db();
        let mut track = sample("/m/a.mp3", "T", "A", "Al", 1000);
        track.size_bytes = 4096;
        track.modified_at = 777;
        db.upsert_track(&track).unwrap();

        let known = db.known_files().unwrap();
        assert_eq!(
            known.get("/m/a.mp3"),
            Some(&FileStamp {
                size_bytes: 4096,
                modified_at: 777
            })
        );
    }

    #[test]
    fn all_tracks_honours_sort_order_and_limit() {
        let db = memory_db();
        db.upsert_track(&sample("/m/b.mp3", "Beta", "B", "Al", 2000))
            .unwrap();
        db.upsert_track(&sample("/m/a.mp3", "alpha", "A", "Al", 5000))
            .unwrap();
        db.upsert_track(&sample("/m/c.mp3", "Gamma", "C", "Al", 1000))
            .unwrap();

        let asc = db
            .all_tracks(SortKey::Title, SortOrder::Ascending, None)
            .unwrap();
        // COLLATE NOCASE：大小写不敏感，alpha 应该排在 Beta 前面。
        assert_eq!(
            asc.iter().map(|t| t.title.as_str()).collect::<Vec<_>>(),
            vec!["alpha", "Beta", "Gamma"]
        );

        let desc = db
            .all_tracks(SortKey::Title, SortOrder::Descending, None)
            .unwrap();
        assert_eq!(desc[0].title, "Gamma");

        let limited = db
            .all_tracks(SortKey::Duration, SortOrder::Descending, Some(2))
            .unwrap();
        assert_eq!(limited.len(), 2);
        assert_eq!(limited[0].title, "alpha");
        assert_eq!(limited[1].title, "Beta");
    }

    #[test]
    fn search_treats_wildcards_as_literal_characters() {
        let db = memory_db();
        db.upsert_track(&sample("/m/1.mp3", "100% Pure", "A", "Al", 1000))
            .unwrap();
        db.upsert_track(&sample("/m/2.mp3", "abc", "A", "Al", 1000))
            .unwrap();

        assert_eq!(db.search("100%", 10, Scope::All).unwrap().len(), 1);
        assert_eq!(db.search("% Pu", 10, Scope::All).unwrap().len(), 1);

        // 不转义的话 "a_c" 会匹配 "abc"（因为 `_` 是单字符通配符）。
        assert!(db.search("a_c", 10, Scope::All).unwrap().is_empty());

        assert_eq!(db.search("nope", 10, Scope::All).unwrap().len(), 0);
    }

    #[test]
    fn search_matches_artist_and_album() {
        let db = memory_db();
        db.upsert_track(&sample("/m/1.mp3", "Song", "Radiohead", "Kid A", 1000))
            .unwrap();
        assert_eq!(db.search("radio", 10, Scope::All).unwrap().len(), 1);
        assert_eq!(db.search("kid a", 10, Scope::All).unwrap().len(), 1);
        assert_eq!(db.search("SONG", 10, Scope::All).unwrap().len(), 1);
    }

    /// **索引 ≠ 曲库**：扫描进来（upsert）的歌默认不在曲库里，要用户明确收进来；
    /// 移出曲库只是清标记，记录与文件都还在，所以能被「＋ 添加歌曲」原样找回来。
    #[test]
    fn library_scope_separates_index_from_library() {
        let db = memory_db();
        let a = db
            .upsert_track(&sample("/m/a.mp3", "Alpha", "X", "Al", 60_000))
            .unwrap();
        let b = db
            .upsert_track(&sample("/m/b.mp3", "Beta", "Y", "Al", 120_000))
            .unwrap();

        // 刚建索引：整份索引里有两首，曲库是空的。
        assert_eq!(
            db.all_tracks(SortKey::Title, SortOrder::Ascending, None)
                .unwrap()
                .len(),
            2
        );
        assert!(db
            .library_tracks(SortKey::Title, SortOrder::Ascending, None)
            .unwrap()
            .is_empty());
        assert_eq!(db.pending_tracks(None).unwrap().len(), 2);
        assert_eq!(db.library_stats().unwrap().track_count, 0);
        assert_eq!(db.stats().unwrap().track_count, 2);
        // 搜索框过滤的是曲库列表：没入库的歌不该被搜出来。
        assert!(db.search("alpha", 10, Scope::Library).unwrap().is_empty());
        assert_eq!(db.search("alpha", 10, Scope::All).unwrap().len(), 1);

        // 收进曲库：列表、统计、搜索都跟着变。
        assert_eq!(db.set_in_library(&[a], true).unwrap(), 1);
        assert_eq!(
            db.library_tracks(SortKey::Title, SortOrder::Ascending, None)
                .unwrap()
                .iter()
                .map(|t| t.title.as_str())
                .collect::<Vec<_>>(),
            vec!["Alpha"]
        );
        assert_eq!(db.pending_tracks(None).unwrap().len(), 1);
        let stats = db.library_stats().unwrap();
        assert_eq!(stats.track_count, 1);
        assert_eq!(stats.total_duration_ms, 60_000, "统计的是曲库里的歌");
        assert_eq!(stats.album_count, 1);
        assert_eq!(stats.artist_count, 1);
        assert_eq!(db.search("alpha", 10, Scope::Library).unwrap().len(), 1);

        // 重复设置不算“改变”，也不该出错（多选里连着点两下很常见）。
        assert_eq!(db.set_in_library(&[a], true).unwrap(), 0);

        // 移出曲库：记录还在（能在待入库列表里找回来），只是不在曲库视图里了。
        assert_eq!(db.set_in_library(&[a], false).unwrap(), 1);
        assert!(db
            .library_tracks(SortKey::Title, SortOrder::Ascending, None)
            .unwrap()
            .is_empty());
        assert_eq!(db.pending_tracks(None).unwrap().len(), 2);
        assert_eq!(db.stats().unwrap().track_count, 2, "移出曲库不该删记录");

        // 文件真的没了（重扫剪枝）才会连记录一起消失。
        db.delete_paths(&["/m/b.mp3".to_string()]).unwrap();
        assert_eq!(db.stats().unwrap().track_count, 1);
        assert!(db.track_by_id(b).unwrap().is_none(), "剪枝会连记录一起删掉");
    }

    /// 有些文件标签里没有时长却照样能播（真机上的例子：从 mp4 扒出来、名字叫
    /// `.mp3` 的音频）。播放时用解码器算出来的值把它补上，且**只补 0**：
    /// 已有值来自标签，通常更权威，不该被播放时的观测覆盖。
    #[test]
    fn fill_duration_only_fills_missing_value() {
        let db = memory_db();
        let known = db
            .upsert_track(&sample("/m/a.mp3", "A", "X", "Al", 60_000))
            .unwrap();
        let unknown = db
            .upsert_track(&sample("/m/b.mp3", "B", "Y", "Al", 0))
            .unwrap();
        assert_eq!(db.track_by_id(unknown).unwrap().unwrap().duration_ms, 0);

        assert!(db.fill_duration(unknown, 336_967).unwrap(), "0 应该被补上");
        assert_eq!(
            db.track_by_id(unknown).unwrap().unwrap().duration_ms,
            336_967
        );
        // 再补一次没什么可写的：进度每 2 秒写一次，不能每次都 UPDATE。
        assert!(!db.fill_duration(unknown, 336_967).unwrap());

        assert!(!db.fill_duration(known, 1).unwrap(), "已有值不该被覆盖");
        assert_eq!(db.track_by_id(known).unwrap().unwrap().duration_ms, 60_000);
        assert!(!db.fill_duration(known, 0).unwrap(), "0 不是“补上了”");
    }

    /// v1 → v2 的升级：老库补上 `in_library`，并且**已经打下的歌全部留在曲库里**。
    #[test]
    fn migration_keeps_old_library() {
        let db = memory_db();
        db.upsert_track(&sample("/m/a.mp3", "A", "X", "Al", 1000))
            .unwrap();

        // 把库退回 v1 的样子：没有 in_library 这一列（索引依赖它，得先删掉）。
        db.conn
            .execute_batch(
                "DROP INDEX idx_track_library;
                 ALTER TABLE track DROP COLUMN in_library;",
            )
            .unwrap();

        db.migrate().unwrap();

        let stored = db.track_by_path("/m/a.mp3").unwrap().unwrap();
        assert_eq!(
            db.library_tracks(SortKey::Title, SortOrder::Ascending, None)
                .unwrap()
                .len(),
            1,
            "升级后老歌必须还在曲库里"
        );
        assert!(db.pending_tracks(None).unwrap().is_empty());
        assert_eq!(stored.path, "/m/a.mp3");

        // 升级之后再扫进来的新歌仍然默认不入库。
        db.upsert_track(&sample("/m/new.mp3", "New", "X", "Al", 1000))
            .unwrap();
        assert_eq!(db.pending_tracks(None).unwrap().len(), 1);
        assert_eq!(db.library_stats().unwrap().track_count, 1);
    }

    /// 播放列表：新建 → 加歌（不重复）→ 改顺序后按下标删 → 按 id 删 → 级联删除。
    #[test]
    fn playlist_roundtrip() {
        let db = memory_db();
        let a = db
            .upsert_track(&sample("/m/a.mp3", "A", "X", "Al", 1000))
            .unwrap();
        let b = db
            .upsert_track(&sample("/m/b.mp3", "B", "X", "Al", 2000))
            .unwrap();
        let c = db
            .upsert_track(&sample("/m/c.mp3", "C", "X", "Al", 3000))
            .unwrap();

        let list = db.create_playlist("  学习  ").unwrap();
        assert_eq!(name_of(&db, list), "学习", "名字应被 trim");
        assert!(db.create_playlist("   ").unwrap() > 0, "空名字要有兜底");

        assert!(db.add_to_playlist(list, a).unwrap());
        assert!(db.add_to_playlist(list, b).unwrap());
        assert!(db.add_to_playlist(list, c).unwrap());
        assert!(
            !db.add_to_playlist(list, a).unwrap(),
            "同一列表里不重复添加"
        );
        assert_eq!(count_of(&db, list), 3);

        // 顺序就是加入顺序。
        let titles: Vec<String> = db
            .playlist_tracks(list)
            .unwrap()
            .into_iter()
            .map(|t| t.title)
            .collect();
        assert_eq!(titles, vec!["A", "B", "C"]);

        // 按下标删中间那首：剩下的 position 必须补成 0/1。
        db.remove_from_playlist(list, 1).unwrap();
        let titles: Vec<String> = db
            .playlist_tracks(list)
            .unwrap()
            .into_iter()
            .map(|t| t.title)
            .collect();
        assert_eq!(titles, vec!["A", "C"]);
        assert_eq!(positions_of(&db, list), vec![0, 1]);

        // 按 id 删：删掉的不在列表里时返回 false，也不该动别人的位置。
        assert!(db.remove_track_from_playlist(list, a).unwrap());
        assert!(!db.remove_track_from_playlist(list, a).unwrap());
        let titles: Vec<String> = db
            .playlist_tracks(list)
            .unwrap()
            .into_iter()
            .map(|t| t.title)
            .collect();
        assert_eq!(titles, vec!["C"]);
        assert_eq!(positions_of(&db, list), vec![0]);

        // 曲目被重扫移除（级联删除）会留空洞；再按 id 删一次要把它抹平。
        db.add_to_playlist(list, b).unwrap();
        db.add_to_playlist(list, a).unwrap();
        db.delete_paths(&["/m/b.mp3".to_string()]).unwrap();
        assert_eq!(positions_of(&db, list), vec![0, 2], "级联删除会留空洞");
        assert!(db.remove_track_from_playlist(list, a).unwrap());
        assert_eq!(positions_of(&db, list), vec![0], "删完应重新编号");

        // 改名 / 删除列表；曲目本身不受影响。
        db.rename_playlist(list, " 通勤 ").unwrap();
        assert_eq!(name_of(&db, list), "通勤");
        db.delete_playlist(list).unwrap();
        assert_eq!(playlists_len(&db), 1, "只该删掉这一个");
        assert_eq!(db.stats().unwrap().track_count, 2, "删列表不该删曲目");
    }

    /// 导入播放列表：顺序照文件来，对不上的只计数，重复条目只收一次。
    #[test]
    fn import_playlist_keeps_order_and_reports_missing() {
        let db = memory_db();
        db.upsert_track(&sample("/m/a.mp3", "A", "X", "Al", 1000))
            .unwrap();
        db.upsert_track(&sample("/m/b.mp3", "B", "X", "Al", 2000))
            .unwrap();

        let entries: Vec<String> = [
            "/m/b.mp3",             // 顺序：B 在前
            "/m/a.mp3",             // 再来 A
            "/m/b.mp3",             // 重复出现：只算一次
            "/m/never-scanned.mp3", // 索引里没有
            "/m/also-gone.flac",
        ]
        .iter()
        .map(|s| (*s).to_string())
        .collect();

        let result = db.import_playlist("导入的列表", &entries).unwrap();

        assert_eq!(result.added, 2);
        assert_eq!(result.missing, 2);
        assert_eq!(
            result.missing_paths,
            vec!["/m/never-scanned.mp3", "/m/also-gone.flac"]
        );
        assert_eq!(
            name_of(&db, result.playlist_id),
            "导入的列表",
            "列表名照传进来的走"
        );

        // 顺序 = 文件里的顺序，而且 position 是连续的 0/1。
        let titles: Vec<String> = db
            .playlist_tracks(result.playlist_id)
            .unwrap()
            .into_iter()
            .map(|t| t.title)
            .collect();
        assert_eq!(titles, vec!["B", "A"]);
        assert_eq!(positions_of(&db, result.playlist_id), vec![0, 1]);

        // 导入不该顺手把没扫到的文件塞进索引：那是「扫描」的活。
        assert_eq!(db.stats().unwrap().track_count, 2);
    }

    /// 从别人的电脑上导出的列表：路径完全不同，只靠文件名也要认出来。
    #[test]
    fn import_playlist_matches_by_file_name_as_a_fallback() {
        let db = memory_db();
        db.upsert_track(&sample(
            "/storage/emulated/0/Music/song.mp3",
            "歌",
            "X",
            "Al",
            0,
        ))
        .unwrap();

        let entries = vec![r"D:\Music\song.mp3".to_string()];
        let result = db.import_playlist("从电脑导入", &entries).unwrap();

        assert_eq!(result.added, 1);
        assert_eq!(result.missing, 0);
    }

    /// 一条都对不上时也要把列表建出来并如实报数（界面据此提示「先扫描」）。
    #[test]
    fn import_playlist_with_nothing_matching_still_creates_the_list() {
        let db = memory_db();
        let entries = vec!["/m/nope.mp3".to_string()];
        let result = db.import_playlist("空的", &entries).unwrap();

        assert_eq!(result.added, 0);
        assert_eq!(result.missing, 1);
        assert_eq!(db.playlist_tracks(result.playlist_id).unwrap().len(), 0);
        assert!(db.playlist_by_id(result.playlist_id).unwrap().is_some());
        assert!(db.playlist_by_id(9999).unwrap().is_none());
    }

    /// 「接着上次的听」要的是**整份队列**：队列、当前项、进度三样都要对得上。
    #[test]
    fn resume_queue_keeps_the_whole_queue() {
        let db = memory_db();
        let a = db
            .upsert_track(&sample("/m/a.mp3", "A", "X", "Y", 0))
            .unwrap();
        let b = db
            .upsert_track(&sample("/m/b.mp3", "B", "X", "Y", 0))
            .unwrap();
        let c = db
            .upsert_track(&sample("/m/c.mp3", "C", "X", "Y", 0))
            .unwrap();

        assert!(
            db.resume_queue().unwrap().is_none(),
            "没记过队列时不该编一份出来"
        );

        db.save_queue(&[a, b, c], 1).unwrap();
        db.save_position(b, 12_345).unwrap();
        let saved = db.resume_queue().unwrap().expect("应记得整份队列");
        assert_eq!(
            saved.entries.iter().map(|e| e.id).collect::<Vec<_>>(),
            vec![a, b, c],
            "顺序就是播放顺序"
        );
        assert_eq!(saved.entries[0].path, "/m/a.mp3");
        assert_eq!(saved.index, 1, "上次停在第 2 首");
        assert_eq!(saved.position_ms, 12_345, "进度从 play_state 现取");

        // 换一份队列：整表重写，旧的一点不留。
        db.save_queue(&[c, a], 0).unwrap();
        let saved = db.resume_queue().unwrap().expect("换了队列");
        assert_eq!(
            saved.entries.iter().map(|e| e.id).collect::<Vec<_>>(),
            vec![c, a]
        );
        assert_eq!(saved.index, 0);
        assert_eq!(saved.position_ms, 0, "这一首还没放过，从 0 开始");

        // 空队列＝没得接着放。
        db.save_queue(&[], 0).unwrap();
        assert!(db.resume_queue().unwrap().is_none());
    }

    /// 队列里某首曲子被移出曲库：队列自动变短，「上次那一首」照样对准。
    #[test]
    fn resume_queue_survives_removed_tracks() {
        let db = memory_db();
        let a = db
            .upsert_track(&sample("/m/a.mp3", "A", "X", "Y", 0))
            .unwrap();
        let b = db
            .upsert_track(&sample("/m/b.mp3", "B", "X", "Y", 0))
            .unwrap();
        let c = db
            .upsert_track(&sample("/m/c.mp3", "C", "X", "Y", 0))
            .unwrap();

        db.save_queue(&[a, b, c], 2).unwrap();
        db.save_position(c, 5_000).unwrap();

        // 删掉中间那首（从库里移出会级联删掉队列里的那一行）。
        db.delete_paths(&["/m/b.mp3".to_string()]).unwrap();

        let saved = db.resume_queue().unwrap().expect("队列还剩两首");
        assert_eq!(
            saved.entries.iter().map(|e| e.id).collect::<Vec<_>>(),
            vec![a, c]
        );
        assert_eq!(saved.index, 1, "c 从第 3 个挪到了第 2 个");
        assert_eq!(saved.position_ms, 5_000);

        // 连「上次那一首」都被删了：落到队列开头，位置也该归零（不然会跳到别人身上）。
        db.delete_paths(&["/m/c.mp3".to_string()]).unwrap();
        let saved = db.resume_queue().unwrap().expect("还剩一首");
        assert_eq!(saved.index, 0);
        assert_eq!(saved.entries.len(), 1);
        assert_eq!(saved.position_ms, 0);
    }

    /// 下标越界时夹到合法范围：调用方拿的是引擎快照，偶尔会慢半拍。
    #[test]
    fn save_queue_clamps_the_index() {
        let db = memory_db();
        let a = db
            .upsert_track(&sample("/m/a.mp3", "A", "X", "Y", 0))
            .unwrap();
        let b = db
            .upsert_track(&sample("/m/b.mp3", "B", "X", "Y", 0))
            .unwrap();

        db.save_queue(&[a, b], 99).unwrap();
        assert_eq!(db.resume_queue().unwrap().unwrap().index, 1);
    }

    /// 「继续播放」：记住最近动过进度的那一首与位置，曲目没了就不再返回。
    #[test]
    fn resume_point_follows_latest_progress() {
        let db = memory_db();
        let a = db
            .upsert_track(&sample("/m/a.mp3", "A", "X", "Y", 0))
            .unwrap();
        let b = db
            .upsert_track(&sample("/m/b.mp3", "B", "X", "Y", 0))
            .unwrap();

        assert!(db.resume_point().unwrap().is_none(), "还没放过任何东西");

        db.save_position(a, 1_000).unwrap();
        let point = db.resume_point().unwrap().expect("应记得这一首");
        assert_eq!(point.track.id, a);
        assert_eq!(point.position_ms, 1_000);

        // 换歌（同一秒内也可能发生）：后写的那一首才算「上次在放」。
        //
        // 时间戳是**毫秒**精度：两次写入落在同一毫秒里就分不出先后（`ORDER BY` 只能
        // 按行序挑一行），所以这里等一等再写。真实使用中换歌/暂停不会挤在同一毫秒，
        // 这一行是为了让用例不随机器快慢时红时绿。
        std::thread::sleep(std::time::Duration::from_millis(2));
        db.save_position(b, 2_500).unwrap();
        let point = db.resume_point().unwrap().expect("应换成新的一首");
        assert_eq!(point.track.id, b);
        assert_eq!(point.position_ms, 2_500);

        // 回到上一首接着听：进度也要跟着回去（同一行是更新，不是新插入）。
        std::thread::sleep(std::time::Duration::from_millis(2));
        db.save_position(a, 30_000).unwrap();
        let point = db.resume_point().unwrap().expect("应回到上一首");
        assert_eq!(point.track.id, a);
        assert_eq!(point.position_ms, 30_000);
        assert_eq!(
            db.play_state(a).unwrap().expect("进度应存在").position_ms,
            30_000
        );

        // 曲目被重扫移除：级联删除后不能再给出一个已经不存在的文件。
        db.delete_paths(&["/m/a.mp3".to_string()]).unwrap();
        let point = db.resume_point().unwrap().expect("还有 b 在");
        assert_eq!(point.track.id, b, "没了的那一首不该再被选中");
        db.delete_paths(&["/m/b.mp3".to_string()]).unwrap();
        assert!(
            db.resume_point().unwrap().is_none(),
            "都删了就没什么可接着放"
        );
    }

    /// 按 id 找名字。`playlists()` 是按名字排序的，用下标会随别的列表漂移。
    fn name_of(db: &Db, playlist: PlaylistId) -> String {
        db.playlists()
            .unwrap()
            .into_iter()
            .find(|p| p.id == playlist)
            .map(|p| p.name)
            .expect("列表应存在")
    }

    fn count_of(db: &Db, playlist: PlaylistId) -> u32 {
        db.playlists()
            .unwrap()
            .into_iter()
            .find(|p| p.id == playlist)
            .map(|p| p.track_count)
            .expect("列表应存在")
    }

    fn playlists_len(db: &Db) -> usize {
        db.playlists().unwrap().len()
    }

    /// 某个列表里所有条目的 position（按显示顺序）。
    fn positions_of(db: &Db, playlist: PlaylistId) -> Vec<i64> {
        let mut stmt = db
            .conn
            .prepare("SELECT position FROM playlist_item WHERE playlist_id = ?1 ORDER BY position")
            .expect("prepare");
        let rows = stmt
            .query_map(params![playlist], |row| row.get::<_, i64>(0))
            .expect("query");
        rows.collect::<rusqlite::Result<Vec<_>>>().expect("collect")
    }
}
