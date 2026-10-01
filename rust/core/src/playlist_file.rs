//! 播放列表**文件**的读写：m3u / m3u8 / xspf。
//!
//! 为什么要单独一层：界面拿到的是一个 `content://` 选出来的文件（见 Dart 侧的
//! `PlaylistFiles`），真正的解析放在这里，于是全都**能在宿主机上跑测试**——
//! 各种脏数据（Windows 反斜杠、百分号编码、GBK、CDATA、缺 `#EXTM3U` 头）都能覆盖到，
//! 不必真机试一遍才知道。
//!
//! 与本 crate 的 `db` 模块一样，这里只认「路径」，不碰 SAF：
//! 播放列表文件里的条目最终都要落到曲库里的**真实路径**上。
//!
//! 支持的格式（其余一律不认，见 [`detect_format`]）：
//! - `.m3u` / `.m3u8`：一行一个条目，`#` 开头是注释，`#EXTINF` 里的标题读出来也不用
//!   （匹配靠路径，靠标题只会认错）；也接受不带 `#EXTM3U` 头的纯路径清单。
//! - `.xspf`：只取 `<trackList>` 里的 `<location>`，以及列表自己的 `<title>`。

use std::collections::HashMap;
use std::path::Path;

use crate::error::{CoreError, Result};
use crate::metadata::decode_text;
use crate::models::{PlaylistFileFormat, Track, TrackId};

/// 解析出来的列表：顺序就是播放顺序。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ParsedPlaylist {
    pub format: PlaylistFileFormat,
    /// 文件里自带的名字（xspf 的 `<title>`）；m3u 没有这个概念，永远是 `None`。
    pub name: Option<String>,
    /// 条目路径。相对路径在有 [`parse_with_base`] 给出的基准目录时会拼成绝对路径，
    /// 否则原样返回——后面还有 [`PathIndex`] 的文件名兜底。
    pub entries: Vec<String>,
    /// 网络地址等本地放不了的条目，跳过的条数。
    pub skipped: u32,
}

/// 按扩展名判断格式；扩展名不认识（SAF 有时给不出像样的名字）时嗅探内容。
pub fn detect_format(file_name: &str, bytes: &[u8]) -> Option<PlaylistFileFormat> {
    let ext = Path::new(file_name)
        .extension()
        .and_then(|ext| ext.to_str())
        .map(|ext| ext.to_ascii_lowercase());
    match ext.as_deref() {
        Some("m3u") | Some("m3u8") => return Some(PlaylistFileFormat::M3u),
        Some("xspf") => return Some(PlaylistFileFormat::Xspf),
        _ => {}
    }

    // 只看开头：xml 声明 / 根元素认 xspf，`#EXTM3U` 认 m3u，
    // 剩下的按“第一行是个非空路径”当 m3u 处理（很多导出工具就是不写头）。
    let head_len = bytes.len().min(1024);
    let head = String::from_utf8_lossy(&bytes[..head_len]);
    let head = head.trim_start_matches('\u{feff}').trim_start();
    if head.starts_with('<') {
        return Some(PlaylistFileFormat::Xspf);
    }
    if head.starts_with("#EXTM3U") || head.starts_with("#EXTINF") {
        return Some(PlaylistFileFormat::M3u);
    }
    let first = head.lines().find(|line| !line.trim().is_empty())?;
    (!first.trim().is_empty()).then_some(PlaylistFileFormat::M3u)
}

/// 解析一份播放列表文件（不知道文件所在目录，见 [`parse_with_base`]）。
pub fn parse(file_name: &str, bytes: &[u8]) -> Result<ParsedPlaylist> {
    parse_with_base(file_name, bytes, None)
}

/// 解析一份播放列表文件。
///
/// `base_dir` 是**文件所在目录**：m3u / xspf 里的相对路径都相对它。界面从 SAF 拿到的
/// 是 `content://`，拿不到真实目录，所以传 `None`——那些条目就交给
/// [`PathIndex`] 按文件名去认。
pub fn parse_with_base(
    file_name: &str,
    bytes: &[u8],
    base_dir: Option<&Path>,
) -> Result<ParsedPlaylist> {
    let format = detect_format(file_name, bytes).ok_or_else(|| {
        CoreError::PlaylistFormat(format!(
            "认不出这是什么格式（既不是 m3u / m3u8，也不是 xspf）：{file_name}"
        ))
    })?;
    let text = decode_text(bytes);

    let parsed = match format {
        PlaylistFileFormat::M3u => {
            let (entries, skipped) = parse_m3u(&text, base_dir);
            ParsedPlaylist {
                format,
                name: None,
                entries,
                skipped,
            }
        }
        PlaylistFileFormat::Xspf => {
            let (name, entries, skipped) = parse_xspf(&text, base_dir)?;
            ParsedPlaylist {
                format,
                name,
                entries,
                skipped,
            }
        }
    };

    if parsed.entries.is_empty() {
        return Err(CoreError::PlaylistFormat(format!(
            "这个播放列表里没有任何可以用本地文件播放的条目：{file_name}"
        )));
    }
    Ok(parsed)
}

// ---------------------------------------------------------------------------
// m3u / m3u8
// ---------------------------------------------------------------------------

/// 解析 m3u 文本，返回（条目, 跳过的网络条目数）。
///
/// 逐行读，`#` 开头的一律当注释（`#EXTM3U` / `#EXTINF` / 播放器自己写的 `#EXTALB`）。
/// `#EXTINF` 里的标题**刻意不用**：本应用按路径找歌，标题只会在同名文件上认错人。
fn parse_m3u(text: &str, base_dir: Option<&Path>) -> (Vec<String>, u32) {
    let mut entries = Vec::new();
    let mut skipped = 0;
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        match entry_to_path(line, base_dir) {
            Entry::Path(path) => entries.push(path),
            Entry::Remote => skipped += 1,
            Entry::Unusable => {}
        }
    }
    (entries, skipped)
}

/// 一条条目解析后的归宿。
enum Entry {
    /// 本地路径（相对路径已按基准目录拼成绝对路径）。
    Path(String),
    /// 网络地址（`http://`、`rtsp://` …）：本地播放器放不了，跳过并计数。
    Remote,
    /// 空行、纯空白之类的垃圾，静默丢弃（不计数，免得提示里出现莫名其妙的数字）。
    Unusable,
}

/// 把一条条目转成本地路径。
///
/// 要处理的写法（真机上的列表里都出现过）：
/// - `file:///storage/emulated/0/Music/a.mp3`（xspf 与部分 m3u 都这么写）
/// - `%E5%A4%9C%E6%98%8E%E3%81%91.mp3`（百分号编码，中文名很常见）
/// - `Music/a.mp3`（相对列表文件所在目录）
/// - `"一个 带空格的路径.mp3"`（有的工具会加引号）
fn entry_to_path(entry: &str, base_dir: Option<&Path>) -> Entry {
    let entry = entry.trim().trim_matches('"').trim();
    if entry.is_empty() {
        return Entry::Unusable;
    }

    let without_scheme = if let Some(rest) = strip_file_scheme(entry) {
        rest
    } else if has_remote_scheme(entry) {
        return Entry::Remote;
    } else {
        entry
    };

    let decoded = percent_decode(without_scheme);
    let decoded = decoded.trim();
    if decoded.is_empty() {
        return Entry::Unusable;
    }

    // 相对路径：知道基准目录就拼绝对路径，不知道就原样留着（后面按文件名兜底匹配）。
    let path = Path::new(decoded);
    if path.is_absolute() {
        return Entry::Path(decoded.to_string());
    }
    match base_dir {
        Some(base) => Entry::Path(base.join(decoded).to_string_lossy().into_owned()),
        None => Entry::Path(decoded.to_string()),
    }
}

/// `file://…` → 路径部分。不是 `file:` 开头时返回 `None`。
///
/// 三种写法都要认：`file:///a/b`（空主机）、`file://localhost/a/b`、`file:/a/b`。
fn strip_file_scheme(entry: &str) -> Option<&str> {
    let bytes = entry.as_bytes();
    // 先比较前 5 个字节再切片：`entry[..5]` 在字符串以多字节字符开头时会 panic，
    // 而字节前缀相等就保证了第 5 个字节正好是字符边界。
    if bytes.len() < 5 || !bytes[..5].eq_ignore_ascii_case(b"file:") {
        return None;
    }
    let rest = entry[5..].strip_prefix("//").unwrap_or(&entry[5..]);
    // 主机名部分：`file://host/path` 里 host 到第一个 `/` 为止；
    // `file:///path` 去掉 `//` 后第一个字符就是 `/`，此时没有主机。
    match rest.find('/') {
        Some(index) if index > 0 => Some(&rest[index..]),
        _ => Some(rest),
    }
}

/// 是不是别的协议（http、rtsp、smb…）。判断得很宽：`scheme://` 或 `scheme:` 都算，
/// 反正真正落到本地路径上的条目不会长这样。
fn has_remote_scheme(entry: &str) -> bool {
    let Some(colon) = entry.find(':') else {
        return false;
    };
    let scheme = &entry[..colon];
    if scheme.is_empty() || scheme.len() > 12 {
        return false;
    }
    // 单个字母的「盘符」（`D:\Music`）不算协议：那是 Windows 路径，留着让它去匹配。
    if scheme.len() == 1 {
        return false;
    }
    scheme
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '+' || c == '-' || c == '.')
}

/// 百分号解码。
///
/// 手写而不是引依赖：只处理 `%XX`，非法序列原样保留（网盘导出的列表里偶尔有
/// 只有半个字节的残码）。全程按**字节**处理，避免在多字节字符中间切字符串。
pub fn percent_decode(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            let hex = std::str::from_utf8(&bytes[index + 1..index + 3]).ok();
            if let Some(byte) = hex.and_then(|hex| u8::from_str_radix(hex, 16).ok()) {
                out.push(byte);
                index += 3;
                continue;
            }
        }
        out.push(bytes[index]);
        index += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

// ---------------------------------------------------------------------------
// xspf
// ---------------------------------------------------------------------------

/// 解析 xspf，返回（列表标题, 条目, 跳过的网络条目数）。
///
/// 手写扫描而不是引 XML 库：需要的只有 `<title>` 与 `<trackList>` 里的
/// `<location>` 两样东西，而为了它们拉一个 XML 依赖进核心库并不划算
/// （核心库的依赖列表刻意保持得很短，见 `Cargo.toml`）。
fn parse_xspf(text: &str, base_dir: Option<&Path>) -> Result<(Option<String>, Vec<String>, u32)> {
    if !text.to_ascii_lowercase().contains("<playlist") {
        return Err(CoreError::PlaylistFormat(
            "这个文件看着不是 XSPF：没有 <playlist> 根元素".to_string(),
        ));
    }

    // 列表标题只认 `<trackList>` **之前**的那个 `<title>`——曲目自己的 `<title>`
    // 一个都不能算，否则列表名会变成第一首歌的名字。
    let head = match text.to_ascii_lowercase().find("<tracklist") {
        Some(index) => &text[..index],
        None => text,
    };
    let name = elements(head, "title")
        .iter()
        .find_map(|raw| clean_element(raw));

    let mut entries = Vec::new();
    let mut skipped = 0;
    for raw in elements(text, "location") {
        let Some(location) = clean_element(&raw) else {
            continue;
        };
        match entry_to_path(&location, base_dir) {
            Entry::Path(path) => entries.push(path),
            Entry::Remote => skipped += 1,
            Entry::Unusable => {}
        }
    }
    Ok((name, entries, skipped))
}

/// 取出所有 `<tag>…</tag>` 的内容（大小写不敏感，容忍属性）。
///
/// 用 `to_ascii_lowercase()` 做定位：它只改 ASCII 字节，**字节长度不变**，
/// 所以小写副本上的下标可以直接用来切原串（内容里的中文保持原样）。
fn elements(text: &str, tag: &str) -> Vec<String> {
    let lower = text.to_ascii_lowercase();
    let open = format!("<{tag}");
    let close = format!("</{tag}>");

    let mut out = Vec::new();
    let mut cursor = 0usize;
    while let Some(offset) = lower[cursor..].find(&open) {
        let start = cursor + offset;
        let Some(gt) = lower[start..].find('>') else {
            break;
        };
        let content_start = start + gt + 1;
        let Some(end) = lower[content_start..].find(&close) else {
            break;
        };
        let content_end = content_start + end;
        out.push(text[content_start..content_end].to_string());
        cursor = content_end + close.len();
    }
    out
}

/// 元素内容 → 可用文本：脱掉 CDATA、解 XML 实体、掐空白；空内容返回 `None`。
fn clean_element(raw: &str) -> Option<String> {
    const CDATA_OPEN: &str = "<![CDATA[";
    const CDATA_CLOSE: &str = "]]>";
    let trimmed = raw.trim();

    let text = match trimmed.find(CDATA_OPEN) {
        Some(start) => {
            let body = &trimmed[start + CDATA_OPEN.len()..];
            match body.find(CDATA_CLOSE) {
                Some(end) => &body[..end],
                None => body,
            }
        }
        None => trimmed,
    };
    let text = decode_xml_entities(text);
    let text = text.trim();
    (!text.is_empty()).then(|| text.to_string())
}

/// 解 XML 实体（`&amp;` 这类具名 + `&#123;` / `&#x7B;` 这类数字）。
/// 认不出来的实体原样保留——标题里出现一个 `&nbsp;` 不该让整份列表作废。
fn decode_xml_entities(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut rest = input;
    while let Some(index) = rest.find('&') {
        out.push_str(&rest[..index]);
        let tail = &rest[index..];
        let Some(semi) = tail.find(';') else {
            out.push_str(tail);
            return out;
        };
        // 真实体都很短；隔了十几个字符还没结束的 `;` 说明这个 `&` 只是普通字符。
        if semi > 12 {
            out.push('&');
            rest = &tail[1..];
            continue;
        }
        let entity = &tail[1..semi];
        match entity {
            "amp" => out.push('&'),
            "lt" => out.push('<'),
            "gt" => out.push('>'),
            "quot" => out.push('"'),
            "apos" => out.push('\''),
            other => match numeric_entity(other) {
                Some(decoded) => out.push(decoded),
                None => out.push_str(&tail[..=semi]),
            },
        }
        rest = &tail[semi + 1..];
    }
    out.push_str(rest);
    out
}

/// `#123` / `#x7B` → 字符。
fn numeric_entity(entity: &str) -> Option<char> {
    let code = if let Some(hex) = entity
        .strip_prefix("#x")
        .or_else(|| entity.strip_prefix("#X"))
    {
        u32::from_str_radix(hex, 16).ok()?
    } else {
        entity.strip_prefix('#')?.parse::<u32>().ok()?
    };
    char::from_u32(code)
}

// ---------------------------------------------------------------------------
// 条目 → 曲库曲目
// ---------------------------------------------------------------------------

/// 「播放列表条目 → 曲库曲目」的匹配索引。
///
/// 三级匹配，一级比一级宽松：
/// 1. 完整路径一模一样（同一台机器上导出的列表都命中这一级）；
/// 2. 归一之后相同（只差大小写，或者用了 `\` 而不是 `/`）；
/// 3. **文件名唯一**命中——从电脑上导出的列表写的是 `D:\Music\歌.mp3`，
///    手机上的同一首歌在 `/storage/emulated/0/Music/歌.mp3`，只有文件名还对得上。
///    两个不同目录里有同名文件（撞车）时**不猜**，算对不上：
///    宁可少导入几首，也不要把用户的列表塞进错歌。
#[derive(Debug, Default)]
pub struct PathIndex {
    exact: HashMap<String, TrackId>,
    normalized: HashMap<String, TrackId>,
    /// 文件名 → 唯一的那首；撞车时是 `None`。
    by_name: HashMap<String, Option<TrackId>>,
}

impl PathIndex {
    /// 用「路径 + 曲目 id」建索引。
    pub fn new(entries: impl IntoIterator<Item = (String, TrackId)>) -> Self {
        let mut index = PathIndex::default();
        for (path, id) in entries {
            index.exact.entry(path.clone()).or_insert(id);
            index.normalized.entry(normalize_path(&path)).or_insert(id);
            let name = file_name_key(&path);
            if name.is_empty() {
                continue;
            }
            index
                .by_name
                .entry(name)
                .and_modify(|found| *found = None)
                .or_insert(Some(id));
        }
        index
    }

    /// 找这条条目对应的曲目。对不上返回 `None`（调用方把它算进「对不上」的条数）。
    pub fn resolve(&self, entry: &str) -> Option<TrackId> {
        let entry = entry.trim();
        if entry.is_empty() {
            return None;
        }
        if let Some(id) = self.exact.get(entry) {
            return Some(*id);
        }
        if let Some(id) = self.normalized.get(&normalize_path(entry)) {
            return Some(*id);
        }
        self.by_name.get(&file_name_key(entry)).copied().flatten()
    }
}

/// 归一路径：反斜杠换成斜杠、掐掉两端空白、转小写。
fn normalize_path(path: &str) -> String {
    path.trim().replace('\\', "/").to_lowercase()
}

/// 归一之后的文件名（最后一段）。
fn file_name_key(path: &str) -> String {
    normalize_path(path)
        .rsplit('/')
        .next()
        .unwrap_or_default()
        .trim()
        .to_string()
}

// ---------------------------------------------------------------------------
// 导出
// ---------------------------------------------------------------------------

/// 把列表导出成文本。
///
/// `name` 只有 xspf 用得上——m3u 里压根没有「列表标题」这个概念，传进来也是被忽略；
/// 参数照收不误，调用方不必知道这个差别。
pub fn export(format: PlaylistFileFormat, name: &str, tracks: &[Track]) -> String {
    match format {
        PlaylistFileFormat::M3u => export_m3u8(tracks),
        PlaylistFileFormat::Xspf => export_xspf(name, tracks),
    }
}

/// 导出成 m3u8（UTF-8）：`#EXTM3U` 头 + 每首一条 `#EXTINF` 和一行路径。
pub fn export_m3u8(tracks: &[Track]) -> String {
    let mut out = String::from("#EXTM3U\n");
    for track in tracks {
        out.push_str(&format!(
            "#EXTINF:{},{}\n",
            track.duration_ms / 1000,
            extinf_title(track)
        ));
        out.push_str(&single_line(&track.path));
        out.push('\n');
    }
    out
}

/// `#EXTINF` 后面的显示名：`艺术家 - 标题`，没有艺术家时就是标题。
///
/// 这个字段只是为了别的播放器看着舒服，导入时本应用并不读它（见 [`parse_m3u`]）。
fn extinf_title(track: &Track) -> String {
    let title = track.display_title().trim();
    match artist_of(track) {
        Some(artist) => single_line(&format!("{artist} - {title}")),
        None => single_line(title),
    }
}

/// 导出成 xspf。
pub fn export_xspf(name: &str, tracks: &[Track]) -> String {
    let mut out = String::from("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    out.push_str("<playlist version=\"1\" xmlns=\"http://xspf.org/ns/0/\">\n");
    out.push_str(&format!("  <title>{}</title>\n", escape_xml(name)));
    out.push_str("  <trackList>\n");
    for track in tracks {
        out.push_str("    <track>\n");
        out.push_str(&format!(
            "      <location>{}</location>\n",
            escape_xml(&file_url(&track.path))
        ));
        out.push_str(&format!(
            "      <title>{}</title>\n",
            escape_xml(track.display_title())
        ));
        if let Some(artist) = artist_of(track) {
            out.push_str(&format!(
                "      <creator>{}</creator>\n",
                escape_xml(artist)
            ));
        }
        if let Some(album) = non_empty(track.album.as_deref()) {
            out.push_str(&format!("      <album>{}</album>\n", escape_xml(album)));
        }
        out.push_str(&format!(
            "      <duration>{}</duration>\n",
            track.duration_ms
        ));
        out.push_str("    </track>\n");
    }
    out.push_str("  </trackList>\n</playlist>\n");
    out
}

/// 本地路径 → `file://` URL（xspf 的 `<location>` 要的是 URI 而不是路径）。
///
/// 返回值还要再过一遍 [`escape_xml`]：URI 里的 `&`、`'` 在 XML 里必须写成实体，
/// 否则导出的文件本身就是坏的 XML。
pub fn file_url(path: &str) -> String {
    let normalized = path.trim().replace('\\', "/");
    let absolute = if normalized.starts_with('/') {
        normalized
    } else {
        format!("/{normalized}")
    };
    format!("file://{}", percent_encode(&absolute))
}

/// 按字节做百分号编码：`/` 与 URI 里的非保留字符留着，其余（空格、中文、`#`、`?`）全编码。
fn percent_encode(path: &str) -> String {
    const KEEP: &[u8] = b"-._~/!$&'()*+,;=:@";
    let mut out = String::with_capacity(path.len());
    for byte in path.as_bytes() {
        if byte.is_ascii_alphanumeric() || KEEP.contains(byte) {
            out.push(*byte as char);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

/// XML 文本转义。
///
/// 顺手把控制字符（制表与换行除外）换成空格：它们在 XML 1.0 里根本不允许出现，
/// 留着会让导出的文件被别的播放器判为损坏。
fn escape_xml(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in text.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            '\t' | '\n' | '\r' => out.push(ch),
            c if (c as u32) < 0x20 => out.push(' '),
            c => out.push(c),
        }
    }
    out
}

/// m3u 是一行一条，标题里混进换行会把整个文件写坏。
fn single_line(text: &str) -> String {
    text.replace(['\r', '\n'], " ").trim().to_string()
}

/// 取非空的艺术家名。
fn artist_of(track: &Track) -> Option<&str> {
    non_empty(track.artist.as_deref())
}

/// `Some` 且不是空白串才算有值。
fn non_empty(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|text| !text.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::Track;

    fn track(id: TrackId, path: &str) -> Track {
        Track {
            id,
            path: path.to_string(),
            ..Default::default()
        }
    }

    #[test]
    fn format_comes_from_extension_first_then_content() {
        // 扩展名说了算。
        assert_eq!(
            detect_format("a.m3u", b"whatever"),
            Some(PlaylistFileFormat::M3u)
        );
        assert_eq!(
            detect_format("a.M3U8", b"whatever"),
            Some(PlaylistFileFormat::M3u)
        );
        assert_eq!(
            detect_format("a.xspf", b"whatever"),
            Some(PlaylistFileFormat::Xspf)
        );

        // 名字不认识（SAF 有时给的就是一串 id）时看内容。
        assert_eq!(
            detect_format("12345", b"<?xml version=\"1.0\"?><playlist/>"),
            Some(PlaylistFileFormat::Xspf)
        );
        assert_eq!(
            detect_format("12345", b"#EXTM3U\n/a.mp3\n"),
            Some(PlaylistFileFormat::M3u)
        );
        // 没有 #EXTM3U 头的纯路径清单（很多导出工具就是这么写的）也算 m3u。
        assert_eq!(
            detect_format("12345", b"/storage/emulated/0/Music/a.mp3\n"),
            Some(PlaylistFileFormat::M3u)
        );
        assert_eq!(detect_format("12345", b"   \n"), None);
        assert_eq!(detect_format("12345", b""), None);
    }

    #[test]
    fn m3u_skips_comments_and_resolves_relative_paths() {
        let bytes = b"#EXTM3U\r\n#EXTINF:213,Some Artist - Song\r\nSong.mp3\r\n\r\n#EXTALB:x\r\nsub/Other.mp3\r\n";
        let parsed = parse_with_base("mix.m3u8", bytes, Some(Path::new("/sdcard/Music"))).unwrap();

        assert_eq!(parsed.format, PlaylistFileFormat::M3u);
        assert_eq!(parsed.name, None);
        assert_eq!(
            parsed.entries,
            vec!["/sdcard/Music/Song.mp3", "/sdcard/Music/sub/Other.mp3"]
        );
        assert_eq!(parsed.skipped, 0);
    }

    #[test]
    fn m3u_understands_file_urls_quotes_and_percent_encoding() {
        let bytes = "/storage/emulated/0/Music/%E5%A4%9C%E6%98%8E%E3%81%91.mp3\n\
                     file:///storage/emulated/0/Music/a%20b.flac\n\
                     file://localhost/storage/emulated/0/Music/c.mp3\n\
                     file:/storage/emulated/0/Music/d.mp3\n\
                     \"quoted path.mp3\"\n\
                     http://example.com/stream.mp3\n\
                     rtsp://example.com/live\n";
        let parsed = parse("mix.m3u", bytes.as_bytes()).unwrap();

        assert_eq!(
            parsed.entries,
            vec![
                "/storage/emulated/0/Music/夜明け.mp3",
                "/storage/emulated/0/Music/a b.flac",
                "/storage/emulated/0/Music/c.mp3",
                "/storage/emulated/0/Music/d.mp3",
                "quoted path.mp3",
            ]
        );
        assert_eq!(parsed.skipped, 2, "两条网络地址要单独计数");
    }

    #[test]
    fn m3u_reads_gbk_encoded_files() {
        // 「中文歌.mp3」的 GB18030 字节。中文圈的列表大量是这个编码。
        let mut bytes = b"#EXTM3U\n".to_vec();
        bytes.extend_from_slice(&[0xD6, 0xD0, 0xCE, 0xC4, 0xB8, 0xE8, b'.', b'm', b'p', b'3']);
        bytes.push(b'\n');

        let parsed = parse("gbk.m3u", &bytes).unwrap();
        assert_eq!(parsed.entries, vec!["中文歌.mp3"]);
    }

    #[test]
    fn xspf_reads_title_and_locations() {
        let xml = r#"<?xml version="1.0" encoding="UTF-8"?>
<playlist version="1" xmlns="http://xspf.org/ns/0/">
  <title>夜跑 &amp; 通勤</title>
  <trackList>
    <track>
      <location>file:///storage/emulated/0/Music/a.mp3</location>
      <title>不该被当成列表名</title>
    </track>
    <track>
      <location><![CDATA[file:///storage/emulated/0/Music/b%20c.flac]]></location>
    </track>
    <track>
      <location>https://example.com/stream.mp3</location>
    </track>
  </trackList>
</playlist>"#;
        let parsed = parse("mix.xspf", xml.as_bytes()).unwrap();

        assert_eq!(parsed.format, PlaylistFileFormat::Xspf);
        assert_eq!(parsed.name.as_deref(), Some("夜跑 & 通勤"));
        assert_eq!(
            parsed.entries,
            vec![
                "/storage/emulated/0/Music/a.mp3",
                "/storage/emulated/0/Music/b c.flac",
            ]
        );
        assert_eq!(parsed.skipped, 1);
    }

    #[test]
    fn xspf_relative_locations_use_the_base_dir() {
        let xml = r#"<playlist><title>Mix</title><trackList>
            <track><location>Music/a.mp3</location></track>
            <track><location>./b.mp3</location></track>
        </trackList></playlist>"#;
        let parsed =
            parse_with_base("mix.xspf", xml.as_bytes(), Some(Path::new("/sdcard"))).unwrap();

        assert_eq!(
            parsed.entries,
            vec!["/sdcard/Music/a.mp3", "/sdcard/./b.mp3"]
        );
    }

    #[test]
    fn unusable_files_are_rejected_with_a_reason() {
        let empty = parse("empty.m3u", b"#EXTM3U\n\n# only comments\n").unwrap_err();
        assert!(empty.to_string().contains("没有任何"), "{empty}");

        let not_xspf = parse("broken.xspf", b"<html><body>hi</body></html>").unwrap_err();
        assert!(not_xspf.to_string().contains("XSPF"), "{not_xspf}");
    }

    #[test]
    fn index_matches_exact_then_normalized_then_unique_name() {
        let index = PathIndex::new(vec![
            ("/storage/emulated/0/Music/Alpha.mp3".to_string(), 1),
            ("/storage/emulated/0/Music/Beta.flac".to_string(), 2),
        ]);

        assert_eq!(
            index.resolve("/storage/emulated/0/Music/Alpha.mp3"),
            Some(1)
        );
        // 只差大小写或分隔符：还是同一首歌。
        assert_eq!(
            index.resolve("/storage/emulated/0/Music/alpha.MP3"),
            Some(1)
        );
        assert_eq!(index.resolve(r"D:\Music\beta.flac"), Some(2));
        // 只有文件名对得上：从别的机器导出的列表就长这样。
        assert_eq!(index.resolve("beta.flac"), Some(2));
        assert_eq!(index.resolve("/wherever/Music/Alpha.mp3"), Some(1));
        assert_eq!(index.resolve("/storage/emulated/0/Music/missing.mp3"), None);
        assert_eq!(index.resolve("   "), None);
    }

    #[test]
    fn index_refuses_to_guess_between_same_named_tracks() {
        let index = PathIndex::new(vec![
            ("/a/Music/song.mp3".to_string(), 1),
            ("/b/Music/song.mp3".to_string(), 2),
        ]);

        // 路径完整时当然能分清。
        assert_eq!(index.resolve("/a/Music/song.mp3"), Some(1));
        // 只剩文件名时有两个候选，谁也不比谁更对：算对不上。
        assert_eq!(index.resolve("song.mp3"), None);
        assert_eq!(index.resolve("D:/Music/song.mp3"), None);
    }

    #[test]
    fn exported_m3u8_can_be_parsed_back() {
        let mut first = track(1, "/storage/emulated/0/Music/夜明け と 蛍.mp3");
        first.title = "夜明けと蛍".to_string();
        first.artist = Some("n-buna".to_string());
        first.duration_ms = 309_000;
        let second = track(2, "/storage/emulated/0/Music/b.flac");

        let text = export_m3u8(&[first, second]);
        assert!(text.starts_with("#EXTM3U\n"));
        assert!(text.contains("#EXTINF:309,n-buna - 夜明けと蛍\n"));

        let parsed = parse("out.m3u8", text.as_bytes()).unwrap();
        assert_eq!(
            parsed.entries,
            vec![
                "/storage/emulated/0/Music/夜明け と 蛍.mp3",
                "/storage/emulated/0/Music/b.flac",
            ]
        );
    }

    #[test]
    fn exported_xspf_can_be_parsed_back() {
        let mut first = track(1, "/storage/emulated/0/Music/a & b.mp3");
        first.title = "A <B> \"C\"".to_string();
        first.artist = Some("An & Artist".to_string());
        first.album = Some("Album".to_string());
        first.duration_ms = 1_000;

        let text = export_xspf("我的<列表>", &[first]);
        assert!(text.contains("<title>我的&lt;列表&gt;</title>"));
        assert!(text
            .contains("<location>file:///storage/emulated/0/Music/a%20&amp;%20b.mp3</location>"));
        assert!(text.contains("<duration>1000</duration>"));

        let parsed = parse("out.xspf", text.as_bytes()).unwrap();
        assert_eq!(parsed.name.as_deref(), Some("我的<列表>"));
        assert_eq!(parsed.entries, vec!["/storage/emulated/0/Music/a & b.mp3"]);
    }

    #[test]
    fn export_keeps_titles_on_one_line() {
        let mut broken = track(1, "/storage/emulated/0/Music/a.mp3");
        broken.title = "第一行\n第二行".to_string();

        // 标题里的换行必须被压掉，否则 m3u 会被当成多出来的一行路径。
        assert_eq!(export_m3u8(&[broken]).lines().count(), 3);
    }
}
