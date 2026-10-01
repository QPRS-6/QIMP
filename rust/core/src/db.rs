//! SQLite 索引层。
//!
//! 设计取舍：
//! - **刻意不范式化**。专辑/艺术家直接从 `track` 表 `GROUP BY` 得出，不建独立表。
//!   本地播放器的曲库规模（几千~几万首）下这样更快、更省事，也避免了三张表之间
//!   的一致性维护。将来真的需要艺术家头像之类的数据，再加表也不影响现有 API。
//! - 所有排序字段都走白名单 `match`，绝不把用户输入拼进 SQL。
//! - 路径是唯一键（`UNIQUE(path)`），扫描靠它做 upsert。

use std::collections::HashMap;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{params, Connection, OptionalExtension, Row};

use crate::error::Result;
use crate::models::{
    Album, Artist, PlayState, Playlist, PlaylistId, SortKey, SortOrder, Stats, Track, TrackId,
};

pub(crate) const SCHEMA_VERSION: u32 = 1;

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
    added_at     INTEGER NOT NULL DEFAULT 0
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

    /// 建表 / 升级。当前只有一个版本，但保留 `meta.schema_version` 以便将来迁移。
    pub fn migrate(&self) -> Result<()> {
        self.conn.execute_batch(SCHEMA_SQL)?;
        self.conn.execute(
            "INSERT INTO meta(key, value) VALUES('schema_version', ?1)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![SCHEMA_VERSION.to_string()],
        )?;
        Ok(())
    }
}

/// 当前 Unix 时间（秒）。
pub fn unix_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

impl Db {
    /// 插入或按路径更新一首歌，返回其主键。
    ///
    /// 注意：`added_at` 在更新分支**刻意不覆盖**，保证“最近添加”排序不会因重扫而乱序。
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
    /// 全库列表，支持白名单排序与可选条数限制（`None` = 不限）。
    pub fn all_tracks(
        &self,
        key: SortKey,
        order: SortOrder,
        limit: Option<u32>,
    ) -> Result<Vec<Track>> {
        let sql = format!(
            "SELECT {TRACK_COLUMNS} FROM track ORDER BY {} LIMIT ?1",
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
    pub fn search(&self, query: &str, limit: u32) -> Result<Vec<Track>> {
        let pattern = like_pattern(query);
        let sql = format!(
            "SELECT {TRACK_COLUMNS} FROM track
             WHERE title LIKE ?1 ESCAPE '\\'
                OR artist LIKE ?1 ESCAPE '\\'
                OR album  LIKE ?1 ESCAPE '\\'
                OR album_artist LIKE ?1 ESCAPE '\\'
             ORDER BY title COLLATE NOCASE ASC
             LIMIT ?2"
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

    /// 库统计。
    pub fn stats(&self) -> Result<Stats> {
        let (track_count, total_duration_ms, total_size_bytes) = self.conn.query_row(
            "SELECT COUNT(*), COALESCE(SUM(duration_ms), 0), COALESCE(SUM(size_bytes), 0) FROM track",
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
            "SELECT COUNT(*) FROM (
                 SELECT 1 FROM track
                 WHERE album IS NOT NULL AND TRIM(album) <> ''
                 GROUP BY TRIM(album), COALESCE(TRIM(album_artist), TRIM(artist), '')
             )",
            [],
            |row| row.get(0),
        )?;

        let artist_count: i64 = self.conn.query_row(
            "SELECT COUNT(*) FROM (
                 SELECT 1 FROM track
                 GROUP BY COALESCE(NULLIF(TRIM(COALESCE(artist, '')), ''), '未知艺术家')
             )",
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
    pub fn save_position(&self, track: TrackId, position_ms: u64) -> Result<()> {
        self.conn.execute(
            "INSERT INTO play_state(track_id, position_ms) VALUES(?1, ?2)
             ON CONFLICT(track_id) DO UPDATE SET position_ms = excluded.position_ms",
            params![track, position_ms as i64],
        )?;
        Ok(())
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
    pub fn mark_played(&self, track: TrackId) -> Result<()> {
        self.conn.execute(
            "INSERT INTO play_state(track_id, play_count, last_played_at) VALUES(?1, 1, ?2)
             ON CONFLICT(track_id) DO UPDATE SET
                 play_count     = play_count + 1,
                 last_played_at = excluded.last_played_at",
            params![track, unix_now()],
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

        assert_eq!(db.search("100%", 10).unwrap().len(), 1);
        assert_eq!(db.search("% Pu", 10).unwrap().len(), 1);

        // 不转义的话 "a_c" 会匹配 "abc"（因为 `_` 是单字符通配符）。
        assert!(db.search("a_c", 10).unwrap().is_empty());

        assert_eq!(db.search("nope", 10).unwrap().len(), 0);
    }

    #[test]
    fn search_matches_artist_and_album() {
        let db = memory_db();
        db.upsert_track(&sample("/m/1.mp3", "Song", "Radiohead", "Kid A", 1000))
            .unwrap();
        assert_eq!(db.search("radio", 10).unwrap().len(), 1);
        assert_eq!(db.search("kid a", 10).unwrap().len(), 1);
        assert_eq!(db.search("SONG", 10).unwrap().len(), 1);
    }

    /// 播放列表：新建 → 加歌（不重复）→ 改顺序后按下标删 → 按 id 删 → 级联删除。
    #[test]
    fn playlist_roundtrip() {
        let db = memory_db();
        let a = db.upsert_track(&sample("/m/a.mp3", "A", "X", "Al", 1000)).unwrap();
        let b = db.upsert_track(&sample("/m/b.mp3", "B", "X", "Al", 2000)).unwrap();
        let c = db.upsert_track(&sample("/m/c.mp3", "C", "X", "Al", 3000)).unwrap();

        let list = db.create_playlist("  学习  ").unwrap();
        assert_eq!(name_of(&db, list), "学习", "名字应被 trim");
        assert!(db.create_playlist("   ").unwrap() > 0, "空名字要有兜底");

        assert!(db.add_to_playlist(list, a).unwrap());
        assert!(db.add_to_playlist(list, b).unwrap());
        assert!(db.add_to_playlist(list, c).unwrap());
        assert!(!db.add_to_playlist(list, a).unwrap(), "同一列表里不重复添加");
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
