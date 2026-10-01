//! 元数据读取（基于 lofty）。
//!
//! 三条原则：
//! 1. **绝不因为一个脏标签就丢掉整首歌**。解析失败时退化到“文件名启发式”，
//!    只有连 `stat` 都失败才真正报错。
//! 2. 图片 MIME 由我们自己嗅探魔数，不依赖 lofty 的 `MimeType` 字符串转换，
//!    这样封面缓存层的实现不受上游 API 变动影响。
//! 3. 封面优先取内嵌图，其次取同目录的 `cover.jpg` / `folder.jpg` 等约定文件名。

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use lofty::file::{AudioFile, TaggedFile, TaggedFileExt};
use lofty::probe::Probe;
use lofty::tag::{Accessor, ItemKey, Tag};

use crate::error::Result;
use crate::lyric::{parse_lrc, parse_plain, Lyrics};
use crate::models::Track;

/// 单独抽出来的封面数据。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Cover {
    pub mime: String,
    pub data: Vec<u8>,
}

/// 同目录下按优先级查找的封面文件名。
const SIBLING_COVER_NAMES: &[&str] = &[
    "cover.jpg",
    "cover.jpeg",
    "cover.png",
    "cover.webp",
    "folder.jpg",
    "folder.jpeg",
    "folder.png",
    "album.jpg",
    "albumart.jpg",
    "front.jpg",
];

/// 读标签 + 属性；`None` 表示这份文件实在解析不了（交给调用方走文件名兜底）。
///
/// **必须按内容嗅探类型**：`lofty::read_from_path` 只认扩展名，而它把 `.ogg` 一律
/// 当成 Vorbis —— Opus 编码的 `.ogg`（手机录音、不少下载源都是）会因此整份解析失败，
/// 结果就是标题退化成文件名、时长变成 0（列表里显示 `--:--`，进度条也没法用）。
/// `guess_file_type()` 会先读文件头，认不出来时才保留“按扩展名”的猜测，
/// 所以不会比原来更差。
fn read_tagged(path: &Path) -> Option<TaggedFile> {
    Probe::open(path)
        .map_err(|_| ())
        .and_then(|probe| probe.guess_file_type().map_err(|_| ()))
        .and_then(|probe| probe.read().map_err(|_| ()))
        // 嗅探这条路万一也不行，退回最初那套“按扩展名解析”。
        .or_else(|_| lofty::read_from_path(path))
        .ok()
}

/// 读取单个音频文件的完整信息。
pub fn read(path: impl AsRef<Path>) -> Result<Track> {
    let path = path.as_ref();
    let (size_bytes, modified_at) = file_stamp(path)?;

    let tagged = match read_tagged(path) {
        Some(tagged) => tagged,
        // 解析失败也要给出一条记录，否则用户的破损文件会“凭空消失”。
        None => return Ok(fallback_track(path, size_bytes, modified_at)),
    };

    let tag = tagged.primary_tag().or_else(|| tagged.first_tag());
    let props = tagged.properties();

    let guessed = guess_from_filename(path);
    let has_cover = tag.map(|t| !t.pictures().is_empty()).unwrap_or(false)
        || find_sibling_cover(path).is_some();

    let track = Track {
        id: 0,
        path: path.to_string_lossy().into_owned(),
        title: tag
            .and_then(|t| clean(t.title()))
            .or(guessed.title)
            .unwrap_or_else(|| file_stem(path)),
        artist: tag.and_then(|t| clean(t.artist())).or(guessed.artist),
        album: tag.and_then(|t| clean(t.album())),
        album_artist: tag.and_then(|t| clean(t.get_string(ItemKey::AlbumArtist))),
        genre: tag.and_then(|t| clean(t.genre())),
        year: tag.and_then(read_year).or(guessed.year),
        track_no: tag.and_then(|t| t.track()).or(guessed.track_no),
        disc_no: tag.and_then(|t| t.disk()),
        duration_ms: props.duration().as_millis() as u64,
        bitrate: props.overall_bitrate(),
        sample_rate: props.sample_rate(),
        channels: props.channels(),
        size_bytes,
        modified_at,
        has_cover,
        added_at: 0,
    };
    Ok(track)
}

/// 只拿封面，不解析整首歌的标签。
pub fn read_cover(path: impl AsRef<Path>) -> Result<Option<Cover>> {
    let path = path.as_ref();

    if let Some(tagged) = read_tagged(path) {
        let tag = tagged.primary_tag().or_else(|| tagged.first_tag());
        if let Some(picture) = tag.and_then(|t| t.pictures().first()) {
            let data = picture.data().to_vec();
            if let Some(mime) = sniff_image_mime(&data) {
                return Ok(Some(Cover {
                    mime: mime.to_string(),
                    data,
                }));
            }
        }
    }

    if let Some(cover_path) = find_sibling_cover(path) {
        let data = fs::read(&cover_path)?;
        if let Some(mime) = sniff_image_mime(&data) {
            return Ok(Some(Cover {
                mime: mime.to_string(),
                data,
            }));
        }
    }

    Ok(None)
}

/// 一首歌的歌词：**同目录同名的 `.lrc` 优先**，其次文件里内嵌的歌词。
///
/// `None` 表示两处都没有可显示的内容。`.lrc` 读不到（编码怪、权限不足）时会继续
/// 看内嵌歌词，而不是直接报错——歌词只是锦上添花，不该让播放界面变成错误页。
pub fn read_lyrics(path: impl AsRef<Path>) -> Result<Option<Lyrics>> {
    let path = path.as_ref();

    if let Some(lrc) = find_sibling_lrc(path) {
        if let Ok(bytes) = fs::read(&lrc) {
            if let Some(lyrics) = lyrics_from_text(&decode_text(&bytes)) {
                return Ok(Some(lyrics));
            }
        }
    }

    if let Some(tagged) = read_tagged(path) {
        let tag = tagged.primary_tag().or_else(|| tagged.first_tag());
        if let Some(lyrics) = tag.and_then(embedded_lyrics) {
            return Ok(Some(lyrics));
        }
    }

    Ok(None)
}

/// 从标签里取内嵌歌词。
///
/// 两个键都得看：ID3v2 用的是 `USLT` → [`ItemKey::UnsyncLyrics`]
/// （`ItemKey::Lyrics` 在 ID3v2 里对应的是带时间戳的 `SYLT`，lofty 明确不支持写入），
/// 而 Vorbis 的 `LYRICS` / MP4 的 `©lyr` 走 `Lyrics`。
/// 两个键都有时优先能给出时间轴的那份，另一份留作兜底。
fn embedded_lyrics(tag: &Tag) -> Option<Lyrics> {
    let mut fallback: Option<Lyrics> = None;
    for key in [ItemKey::UnsyncLyrics, ItemKey::Lyrics] {
        let Some(lyrics) = tag.get_string(key).and_then(lyrics_from_text) else {
            continue;
        };
        if lyrics.synced {
            return Some(lyrics);
        }
        fallback = fallback.or(Some(lyrics));
    }
    fallback
}

/// 一段文本 → 歌词：解析出时间轴就用时间轴，否则退化成纯文本（`synced = false`）。
fn lyrics_from_text(raw: &str) -> Option<Lyrics> {
    let synced = parse_lrc(raw);
    if synced.synced {
        return Some(synced);
    }
    let plain = parse_plain(raw);
    (!plain.lines.is_empty()).then_some(plain)
}

/// 同目录下与音频**同名**的 `.lrc`（扩展名大小写不敏感）。
fn find_sibling_lrc(path: &Path) -> Option<PathBuf> {
    let dir = path.parent()?;
    let stem = path.file_stem()?.to_string_lossy().into_owned();

    // 先直接试最常见的写法，省掉一次目录遍历。
    let direct = dir.join(format!("{stem}.lrc"));
    if direct.is_file() {
        return Some(direct);
    }

    // 手机上从电脑复制过来的歌词常是 `Song.LRC`，得按大小写不敏感再找一遍。
    for entry in fs::read_dir(dir).ok()?.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy().into_owned();
        let Some((file_stem, ext)) = name.rsplit_once('.') else {
            continue;
        };
        if !ext.eq_ignore_ascii_case("lrc") || !file_stem.eq_ignore_ascii_case(&stem) {
            continue;
        }
        let candidate = entry.path();
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

/// 文本文件的字节 → 字符串（BOM → UTF-8 → GB18030）。
///
/// 顺序是「BOM → UTF-8 → GB18030」：中文圈的 `.lrc` 与 m3u 大量是 GBK/GB18030 编码
/// （各播放器导出、下载站给的都是），直接当 UTF-8 读会整片变成 `���`。
/// GB18030 是 GBK 的超集，认不出的字节会变成替换字符，但中文能正常显示。
///
/// 播放列表（`playlist_file`）也用它，所以是 `pub(crate)`：解码规则只有这一处。
pub(crate) fn decode_text(bytes: &[u8]) -> String {
    use encoding_rs::{GB18030, UTF_16BE, UTF_16LE};

    if let Some(body) = bytes.strip_prefix(&[0xFF, 0xFE]) {
        return UTF_16LE.decode(body).0.into_owned();
    }
    if let Some(body) = bytes.strip_prefix(&[0xFE, 0xFF]) {
        return UTF_16BE.decode(body).0.into_owned();
    }
    let body = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(bytes);
    if let Ok(text) = std::str::from_utf8(body) {
        return text.to_string();
    }
    GB18030.decode(body).0.into_owned()
}

/// 文件的大小与 mtime（秒）。这是增量扫描的唯一依据。
pub fn file_stamp(path: &Path) -> Result<(u64, i64)> {
    let meta = fs::metadata(path)?;
    let mtime = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or_else(now_secs);
    Ok((meta.len(), mtime))
}

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// 统一处理两种标签取值：`Option<Cow<str>>`（`Accessor`）与 `Option<&str>`（`ItemKey`）。
fn clean(value: Option<impl AsRef<str>>) -> Option<String> {
    value
        .map(|v| v.as_ref().trim().to_string())
        .filter(|v| !v.is_empty())
}

/// 年份优先取 `Year`，退而求其次取 `RecordingDate`（`1999-05-01` 这类）。
fn read_year(tag: &Tag) -> Option<u32> {
    for key in [ItemKey::Year, ItemKey::RecordingDate] {
        if let Some(parsed) = tag.get_string(key).and_then(parse_year) {
            return Some(parsed);
        }
    }
    None
}

fn parse_year(raw: &str) -> Option<u32> {
    let digits: String = raw
        .trim()
        .chars()
        .take_while(|c| c.is_ascii_digit())
        .take(4)
        .collect();
    if digits.len() != 4 {
        return None;
    }
    let year: u32 = digits.parse().ok()?;
    // 合理区间过滤，避免把 "0000" 或 "99999" 当年份。
    (1000..=2999).contains(&year).then_some(year)
}

/// 标签解析失败时的兜底记录。
fn fallback_track(path: &Path, size_bytes: u64, modified_at: i64) -> Track {
    let guessed = guess_from_filename(path);
    Track {
        id: 0,
        path: path.to_string_lossy().into_owned(),
        title: guessed.title.unwrap_or_else(|| file_stem(path)),
        artist: guessed.artist,
        album: None,
        album_artist: None,
        genre: None,
        year: guessed.year,
        track_no: guessed.track_no,
        disc_no: None,
        duration_ms: 0,
        bitrate: None,
        sample_rate: None,
        channels: None,
        size_bytes,
        modified_at,
        has_cover: find_sibling_cover(path).is_some(),
        added_at: 0,
    }
}

/// 文件名启发式解析结果。
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct GuessedName {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub track_no: Option<u32>,
    pub year: Option<u32>,
}

/// 从文件名猜信息。支持的常见形态：
/// - `01 - Artist - Title.mp3`
/// - `Artist - Title.mp3`
/// - `01 Title.flac`
/// - `Title (1999).mp3`
///
/// 约定：`A - B` 视为 `艺术家 - 标题`（网络下载最常见的形式），无法判断时一律当标题。
pub fn guess_from_filename(path: &Path) -> GuessedName {
    let stem = file_stem(path);
    let (track_no, rest) = strip_leading_index(&stem);
    let (rest, year) = strip_trailing_year(&rest);
    let rest = normalize_spaces(&rest);

    if rest.is_empty() {
        return GuessedName {
            title: None,
            artist: None,
            track_no,
            year,
        };
    }

    let parts: Vec<&str> = rest.split(" - ").map(str::trim).collect();
    if parts.len() >= 2 {
        let artist = normalize_spaces(parts[0]);
        let title = normalize_spaces(&parts[1..].join(" - "));
        return GuessedName {
            title: (!title.is_empty()).then_some(title),
            artist: (!artist.is_empty()).then_some(artist),
            track_no,
            year,
        };
    }

    GuessedName {
        title: Some(rest),
        artist: None,
        track_no,
        year,
    }
}

fn file_stem(path: &Path) -> String {
    path.file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// 去掉行首的曲目号：`01 `、`01.`、`01-`、`1_`。
fn strip_leading_index(stem: &str) -> (Option<u32>, String) {
    let digits: String = stem.chars().take_while(|c| c.is_ascii_digit()).collect();
    if digits.is_empty() || digits.len() > 3 {
        return (None, stem.to_string());
    }
    let after = &stem[digits.len()..];
    let trimmed = after.trim_start_matches([' ', '.', '-', '_', ')']);
    // 必须真的消费掉了分隔符，否则 "24K Magic" 会被误判成第 24 首。
    if trimmed.len() == after.len() {
        return (None, stem.to_string());
    }
    (digits.parse().ok(), trimmed.to_string())
}

/// 去掉结尾的 `(1999)` / `[1999]`，并把它作为年份。
fn strip_trailing_year(stem: &str) -> (String, Option<u32>) {
    let trimmed = stem.trim_end();
    let Some(last) = trimmed.chars().last() else {
        return (stem.to_string(), None);
    };
    if last != ')' && last != ']' {
        return (stem.to_string(), None);
    }
    let opening = if last == ')' { '(' } else { '[' };
    let Some(start) = trimmed.rfind(opening) else {
        return (stem.to_string(), None);
    };
    let inner = &trimmed[start + 1..trimmed.len() - 1];
    match parse_year(inner) {
        Some(year) => (trimmed[..start].trim_end().to_string(), Some(year)),
        None => (stem.to_string(), None),
    }
}

/// 把下划线/多个空格统一成单个空格（`Artist_-_Title` 这类）。
fn normalize_spaces(value: &str) -> String {
    let replaced = value.replace('_', " ");
    replaced.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// 同目录封面查找。先按约定名精确匹配，再退化为大小写不敏感扫描
/// （从 Windows/相机拷过来的文件常常是 `Cover.JPG`）。
fn find_sibling_cover(path: &Path) -> Option<PathBuf> {
    let dir = path.parent()?;

    for name in SIBLING_COVER_NAMES {
        let candidate = dir.join(name);
        if candidate.is_file() {
            return Some(candidate);
        }
    }

    let entries = fs::read_dir(dir).ok()?;
    for entry in entries.flatten() {
        let name = entry.file_name();
        let lower = name.to_string_lossy().to_ascii_lowercase();
        if SIBLING_COVER_NAMES.contains(&lower.as_str()) {
            let candidate = entry.path();
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    None
}

/// 用魔数嗅探图片类型。只认播放器封面真正会遇到的几种格式。
pub fn sniff_image_mime(data: &[u8]) -> Option<&'static str> {
    const JPEG: &[u8] = &[0xFF, 0xD8, 0xFF];
    const PNG: &[u8] = &[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];

    if data.starts_with(JPEG) {
        return Some("image/jpeg");
    }
    if data.starts_with(PNG) {
        return Some("image/png");
    }
    if data.starts_with(b"GIF87a") || data.starts_with(b"GIF89a") {
        return Some("image/gif");
    }
    if data.starts_with(b"BM") {
        return Some("image/bmp");
    }
    if data.len() >= 12 && data.starts_with(b"RIFF") && &data[8..12] == b"WEBP" {
        return Some("image/webp");
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn guess(name: &str) -> GuessedName {
        guess_from_filename(Path::new(name))
    }

    /// 回归：`.ogg` 里的 Opus 必须能读出时长/采样率/声道。
    ///
    /// 这里以前是坏的：`lofty::read_from_path` 只按扩展名判断类型，`.ogg` 会被当成
    /// Vorbis，Opus 文件整份解析失败 → 标题退化成文件名、时长 0（列表显示 `--:--`）。
    #[test]
    fn reads_opus_ogg_properties() {
        let track = read(testdata("ogg_opus.ogg")).expect("读 Opus 样本");
        assert_eq!(track.duration_ms, 1000, "1 秒样本应报 1000ms");
        assert_eq!(
            track.sample_rate,
            Some(16000),
            "读的是 OpusHead 里的输入采样率"
        );
        assert_eq!(track.channels, Some(1));
        // 样本里没有 TITLE 标签，标题来自文件名启发式（下划线换成空格）。
        assert_eq!(track.title, "ogg opus");
    }

    /// Vorbis 的 `.ogg` 走同一条路（嗅探不该把它弄坏）。
    #[test]
    fn reads_vorbis_ogg_properties() {
        let track = read(testdata("ogg_vorbis.ogg")).expect("读 Vorbis 样本");
        assert_eq!(track.duration_ms, 1000);
        assert_eq!(track.sample_rate, Some(16000));
        assert_eq!(track.channels, Some(1));
    }

    /// 样本文件的绝对路径（见 `rust/testdata/README.md`）。
    fn testdata(name: &str) -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../testdata")
            .join(name)
    }

    #[test]
    fn parses_year_loosely() {
        assert_eq!(parse_year("1997"), Some(1997));
        assert_eq!(parse_year(" 2024 "), Some(2024));
        assert_eq!(parse_year("2024-05-01"), Some(2024));
        assert_eq!(parse_year("0000"), None);
        assert_eq!(parse_year("19"), None);
        assert_eq!(parse_year("unknown"), None);
    }

    #[test]
    fn guesses_artist_and_title_from_dash_form() {
        let g = guess("/m/01 - Radiohead - Karma Police.mp3");
        assert_eq!(g.track_no, Some(1));
        assert_eq!(g.artist.as_deref(), Some("Radiohead"));
        assert_eq!(g.title.as_deref(), Some("Karma Police"));
    }

    #[test]
    fn guesses_track_number_without_artist() {
        let g = guess("/m/07 Bloom.flac");
        assert_eq!(g.track_no, Some(7));
        assert_eq!(g.title.as_deref(), Some("Bloom"));
        assert_eq!(g.artist, None);
    }

    #[test]
    fn keeps_leading_number_that_is_not_a_track_index() {
        // "24K Magic" 前面没有分隔符，不该被当成第 24 首。
        let g = guess("/m/24K Magic.mp3");
        assert_eq!(g.track_no, None);
        assert_eq!(g.title.as_deref(), Some("24K Magic"));
    }

    #[test]
    fn extracts_trailing_year_bracket() {
        let g = guess("/m/OK Computer (1997).mp3");
        assert_eq!(g.year, Some(1997));
        assert_eq!(g.title.as_deref(), Some("OK Computer"));

        let bracketed = guess("/m/Amnesiac [2001].mp3");
        assert_eq!(bracketed.year, Some(2001));
        assert_eq!(bracketed.title.as_deref(), Some("Amnesiac"));
    }

    #[test]
    fn normalizes_underscores() {
        let g = guess("/m/Radiohead_-_Creep.mp3");
        assert_eq!(g.artist.as_deref(), Some("Radiohead"));
        assert_eq!(g.title.as_deref(), Some("Creep"));
    }

    #[test]
    fn handles_all_conventions_at_once() {
        let g = guess("/m/03 - Air - La Femme d'Argent (1998).flac");
        assert_eq!(g.track_no, Some(3));
        assert_eq!(g.artist.as_deref(), Some("Air"));
        assert_eq!(g.title.as_deref(), Some("La Femme d'Argent"));
        assert_eq!(g.year, Some(1998));
    }

    #[test]
    fn sniffs_image_magic_bytes() {
        assert_eq!(
            sniff_image_mime(&[0xFF, 0xD8, 0xFF, 0xE0]),
            Some("image/jpeg")
        );
        assert_eq!(
            sniff_image_mime(b"\x89PNG\r\n\x1a\n____"),
            Some("image/png")
        );
        assert_eq!(sniff_image_mime(b"GIF89a____"), Some("image/gif"));
        assert_eq!(sniff_image_mime(b"BM______"), Some("image/bmp"));
        assert_eq!(sniff_image_mime(b"RIFF____WEBPVP8 "), Some("image/webp"));
        assert_eq!(sniff_image_mime(b"not an image at all"), None);
        assert_eq!(sniff_image_mime(b""), None);
    }

    #[test]
    fn falls_back_to_filename_when_tags_are_unreadable() {
        // 内容不是音频：解析必然失败，此时必须退化到文件名，而不是丢歌或报错。
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("05 - Artist - Title (2003).mp3");
        fs::write(&file, b"not really audio").unwrap();

        let track = read(&file).unwrap();
        assert_eq!(track.title, "Title");
        assert_eq!(track.artist.as_deref(), Some("Artist"));
        assert_eq!(track.track_no, Some(5));
        assert_eq!(track.year, Some(2003));
        assert_eq!(track.size_bytes, 16);
        assert!(!track.has_cover);
        assert_eq!(track.path, file.to_string_lossy());
    }

    /// 同目录同名的 `.lrc` 优先；文件名大小写不一致也能找到。
    #[test]
    fn reads_sibling_lrc_before_anything_else() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("Song.mp3");
        fs::write(&file, b"x").unwrap();
        fs::write(
            dir.path().join("SONG.LRC"),
            "[ti:标题]\n[00:01.00]第一句\n[00:05.50]第二句\n",
        )
        .unwrap();

        let lyrics = read_lyrics(&file).unwrap().expect("应读到同目录的 .lrc");
        assert!(lyrics.synced);
        assert_eq!(lyrics.title.as_deref(), Some("标题"));
        assert_eq!(lyrics.lines.len(), 2);
        assert_eq!(lyrics.lines[0].time_ms, 1_000);
        assert_eq!(lyrics.lines[1].text, "第二句");
    }

    /// 没有 `.lrc` 时看内嵌歌词：**带时间戳的**按同步歌词处理。
    #[test]
    fn falls_back_to_embedded_synced_lyrics() {
        use lofty::tag::{Tag, TagExt, TagType};

        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("embedded.wav");
        fs::write(&file, minimal_wav(44_100)).unwrap();

        let mut tag = Tag::new(TagType::Id3v2);
        tag.set_title("带内嵌歌词".to_string());
        // ID3v2 的 `USLT` 对应 `UnsyncLyrics`（`Lyrics` 是带时间戳的 `SYLT`，lofty 不支持写）。
        tag.insert_text(ItemKey::UnsyncLyrics, "[00:02.00]内嵌第一句".to_string());
        tag.save_to_path(&file, lofty::config::WriteOptions::default())
            .unwrap();

        let lyrics = read_lyrics(&file).unwrap().expect("应读到内嵌歌词");
        assert!(lyrics.synced, "带时间戳的内嵌歌词应当算同步歌词");
        assert_eq!(lyrics.lines.len(), 1);
        assert_eq!(lyrics.lines[0].time_ms, 2_000);
        assert_eq!(lyrics.lines[0].text, "内嵌第一句");
    }

    /// 内嵌歌词**没有时间戳**（USLT 常见形态）也要能显示，只是标记成不同步。
    #[test]
    fn keeps_plain_text_embedded_lyrics_as_unsynced() {
        use lofty::tag::{Tag, TagExt, TagType};

        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("plain.wav");
        fs::write(&file, minimal_wav(44_100)).unwrap();

        let mut tag = Tag::new(TagType::Id3v2);
        tag.insert_text(ItemKey::UnsyncLyrics, "第一句\n\n第二句\n".to_string());
        tag.save_to_path(&file, lofty::config::WriteOptions::default())
            .unwrap();

        let lyrics = read_lyrics(&file).unwrap().expect("应读到内嵌歌词");
        assert!(!lyrics.synced, "没有时间戳就是不同步歌词");
        assert_eq!(
            lyrics
                .lines
                .iter()
                .map(|line| line.text.as_str())
                .collect::<Vec<_>>(),
            vec!["第一句", "第二句"],
            "空行要被丢掉"
        );
    }

    /// 两种都没有 → `None`（不是报错）。
    #[test]
    fn reports_none_when_there_is_no_lyric() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("silent.mp3");
        fs::write(&file, b"x").unwrap();

        assert!(read_lyrics(&file).unwrap().is_none());
        // 文件本身不存在也不该报错：歌词丢了不影响播放。
        assert!(read_lyrics(dir.path().join("gone.mp3")).unwrap().is_none());
    }

    /// 中文圈的 `.lrc` 大量是 GBK/GB18030：不能整片变成乱码。
    #[test]
    fn decodes_gbk_lrc_files() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("gbk.mp3");
        fs::write(&file, b"x").unwrap();

        // "第一句" 的 GBK 字节（故意不带 BOM）。
        let gbk = [0xB5, 0xDA, 0xD2, 0xBB, 0xBE, 0xE4];
        let mut content = b"[00:01.00]".to_vec();
        content.extend_from_slice(&gbk);
        fs::write(dir.path().join("gbk.lrc"), content).unwrap();

        let lyrics = read_lyrics(&file).unwrap().expect("应读到歌词");
        assert_eq!(lyrics.lines[0].text, "第一句");
    }

    /// 带 UTF-8 BOM 的文件也不能把 BOM 当成歌词内容。
    #[test]
    fn strips_utf8_bom() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("bom.mp3");
        fs::write(&file, b"x").unwrap();

        let mut content = vec![0xEF, 0xBB, 0xBF];
        content.extend_from_slice("[00:01.00]带 BOM".as_bytes());
        fs::write(dir.path().join("bom.lrc"), content).unwrap();

        let lyrics = read_lyrics(&file).unwrap().expect("应读到歌词");
        assert_eq!(lyrics.lines[0].text, "带 BOM");
    }

    #[test]
    fn finds_sibling_cover_case_insensitively() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("song.mp3");
        fs::write(&file, b"x").unwrap();
        fs::write(dir.path().join("Cover.JPG"), [0xFF, 0xD8, 0xFF, 0x00]).unwrap();

        let cover = read_cover(&file).unwrap().unwrap();
        assert_eq!(cover.mime, "image/jpeg");
        assert_eq!(cover.data.len(), 4);

        assert!(read(&file).unwrap().has_cover);
    }

    #[test]
    fn missing_cover_reports_none() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("song.mp3");
        fs::write(&file, b"x").unwrap();

        assert!(read_cover(&file).unwrap().is_none());
        assert!(!read(&file).unwrap().has_cover);
    }

    #[test]
    fn reports_file_stamp() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("song.mp3");
        fs::write(&file, vec![1u8; 32]).unwrap();

        let (size, modified) = file_stamp(&file).unwrap();
        assert_eq!(size, 32);
        assert!(modified > 0);

        assert!(file_stamp(&dir.path().join("nope.mp3")).is_err());
    }

    /// 生成一个最小但合法的 mono/16bit WAV，用于打通真正的解码路径
    /// （前面几个测试的文件都是垃圾字节，只会走兜底分支）。
    fn minimal_wav(samples: u32) -> Vec<u8> {
        let sample_rate: u32 = 44_100;
        let channels: u16 = 1;
        let bits: u16 = 16;
        let data_len: u32 = samples * u32::from(bits / 8);
        let byte_rate: u32 = sample_rate * u32::from(channels) * u32::from(bits / 8);
        let block_align: u16 = channels * (bits / 8);

        let mut out = Vec::with_capacity((44 + data_len) as usize);
        out.extend_from_slice(b"RIFF");
        out.extend_from_slice(&(36 + data_len).to_le_bytes());
        out.extend_from_slice(b"WAVE");
        out.extend_from_slice(b"fmt ");
        out.extend_from_slice(&16u32.to_le_bytes());
        out.extend_from_slice(&1u16.to_le_bytes()); // PCM
        out.extend_from_slice(&channels.to_le_bytes());
        out.extend_from_slice(&sample_rate.to_le_bytes());
        out.extend_from_slice(&byte_rate.to_le_bytes());
        out.extend_from_slice(&block_align.to_le_bytes());
        out.extend_from_slice(&bits.to_le_bytes());
        out.extend_from_slice(b"data");
        out.extend_from_slice(&data_len.to_le_bytes());
        out.resize((44 + data_len) as usize, 0);
        out
    }

    #[test]
    fn reads_real_audio_properties() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("06 - Artist - One Second.wav");
        // 44100 个 16bit 单声道采样 = 恰好 1 秒
        fs::write(&file, minimal_wav(44_100)).unwrap();

        let track = read(&file).unwrap();

        // 无标签 → 标题/艺术家/曲目号来自文件名启发式
        assert_eq!(track.title, "One Second");
        assert_eq!(track.artist.as_deref(), Some("Artist"));
        assert_eq!(track.track_no, Some(6));

        // 这几项只有真正解析成功才会有值
        assert_eq!(track.duration_ms, 1000, "时长应来自容器属性");
        assert_eq!(track.sample_rate, Some(44_100));
        assert_eq!(track.channels, Some(1));
        assert_eq!(track.size_bytes, 44 + 88_200);
        assert!(track.bitrate.is_some(), "WAV 的码率也应由 lofty 给出");
        assert!(track.modified_at > 0);
    }
}
