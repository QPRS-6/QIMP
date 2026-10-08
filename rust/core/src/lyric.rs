//! LRC 歌词解析。
//!
//! 支持：
//! - `[mm:ss]` / `[mm:ss.xx]` / `[mm:ss.xxx]` 三种时间精度
//! - 一行多时间戳（`[00:10.00][01:20.00]同一句`）
//! - **逐字时间轴**（增强型 LRC：`[00:12.00]<00:12.00>今天 <00:12.40>天气 <00:13.10>不错`），
//!   见 [`LyricWord`]；标记的括号也认方括号 / 全角括号那几对，行尾补的那个收尾时间一并剥掉；
//!   没有逐字标记的行照旧整行一条
//! - `[offset:-500]` 全局偏移（毫秒，正数表示歌词提前）
//! - `[ti:]` `[ar:]` `[al:]` 等元信息标签（忽略但不报错）
//! - CRLF 换行、无时间戳的纯文本行（跳过）

use serde::{Deserialize, Serialize};

/// 逐字歌词里的一小段：一段文字 + 它的起始时间。
///
/// 只有**带逐字标记**的行才会有这个列表；没有标记的行 `words` 为空，
/// 界面按整行高亮（老样子）。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LyricWord {
    /// 起始时间（毫秒，已应用 offset）。
    pub time_ms: u64,
    /// 这一段的文字（不含时间标记本身）。
    pub text: String,
}

/// 一条带时间轴的歌词。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LyricLine {
    /// 起始时间（毫秒，已应用 offset）。
    pub time_ms: u64,
    pub text: String,
    /// 逐字时间轴；空表示这一行没有逐字信息。
    ///
    /// 约定：所有 `words` 拼起来等于这一行的原文——同一时间戳的**译文**是合并进
    /// `text`（用 `\n` 连接）的，它没有自己的逐字信息，所以 `words` 只覆盖第一段。
    pub words: Vec<LyricWord>,
}

/// 解析结果：排序后的时间轴 + 元信息。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Lyrics {
    pub lines: Vec<LyricLine>,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub offset_ms: i64,
    /// 有没有可用的时间轴。
    ///
    /// `false` 表示这是**纯文本歌词**（内嵌歌词里很常见：整段文字、没有 `[mm:ss]`）——
    /// 界面只把它当一段可滚动的文字显示，不做高亮、也不自动滚动。
    pub synced: bool,
}

impl Lyrics {
    pub fn is_empty(&self) -> bool {
        self.lines.is_empty()
    }

    /// 返回当前播放位置应当高亮的行下标。
    ///
    /// 约定：当前行 = 最后一个 `time_ms <= position_ms` 的行；
    /// 若播放位置在第一句之前则返回 0，歌词为空返回 `None`。
    pub fn active_index(&self, position_ms: u64) -> Option<usize> {
        if self.lines.is_empty() {
            return None;
        }
        // 时间轴已排序，二分查找避免长歌词每帧线性扫描。
        match self
            .lines
            .binary_search_by(|line| line.time_ms.cmp(&position_ms))
        {
            Ok(idx) => Some(idx),
            Err(0) => Some(0),
            Err(idx) => Some(idx - 1),
        }
    }
}

/// 解析 LRC 文本。无法识别的行会被静默跳过，保证任何脏数据都不会让播放崩溃。
pub fn parse_lrc(raw: &str) -> Lyrics {
    let mut lyrics = Lyrics::default();
    let mut offset_ms: i64 = 0;

    // 第一遍：抓 offset（LRC 规范里 offset 是全局的，与出现顺序无关）。
    for line in raw.lines() {
        if let Some(value) = parse_tag_value(line, "offset") {
            if let Ok(v) = value.trim().parse::<i64>() {
                offset_ms = v;
            }
        }
    }
    lyrics.offset_ms = offset_ms;

    for line in raw.lines() {
        let trimmed = line.trim();
        fill_meta(trimmed, &mut lyrics);

        let (times, text) = split_timestamps(trimmed);
        if times.is_empty() {
            continue;
        }
        let text = text.trim();
        if text.is_empty() {
            continue;
        }
        // 逐字标记要**先**剥掉再判断空：`[00:12.00]<00:12.00>` 这种只有标记没有文字的行
        // 不该算一句。
        let segments = split_word_timestamps(text, times[0]);
        if segments.iter().all(|segment| segment.1.is_empty()) {
            continue;
        }
        let first_time = times[0];
        for time_ms in times {
            let line_time = apply_offset(time_ms, offset_ms);
            // 同一句被多个时间戳复用时（`[00:10][01:20]…<00:12.00>…`），逐字时间要整体
            // 后移同样的量，否则第二次“唱”的时候那串时间早就过去了。
            let shift = time_ms as i64 - first_time as i64;
            lyrics.lines.push(LyricLine {
                time_ms: line_time,
                text: segments
                    .iter()
                    .map(|(_, text)| text.as_str())
                    .collect::<String>(),
                words: words_of(&segments, line_time, offset_ms, shift),
            });
        }
    }

    lyrics.lines.sort_by_key(|l| l.time_ms);
    // 时间戳相同的几句算**同一句**：双语歌词就是同一个时间点两行（原文 + 翻译）。
    // 合成一条、文本里用换行隔开，界面按一条来高亮与滚动，两行一起亮。
    lyrics.lines = merge_same_time(lyrics.lines);
    // 只有带时间戳的行才会被收进来，所以“有行”就等于“有时间轴”。
    lyrics.synced = !lyrics.lines.is_empty();
    lyrics
}

/// 把时间戳相同的相邻行合并成一条（文本之间用 `\n` 连接）。
///
/// 入参必须已按时间排序（[parse_lrc] 里就是这么调过来的）；排序是稳定的，
/// 所以同一个时间点上的多行会保持它们在文件里的先后顺序——原文在前、翻译在后。
///
/// **只并文本**：`words` 保持第一条那份不动。逐字时间轴属于原文，译文没有自己的
/// 逐字信息，把它拼进来只会让「唱到哪个字」算错。
fn merge_same_time(lines: Vec<LyricLine>) -> Vec<LyricLine> {
    let mut merged: Vec<LyricLine> = Vec::with_capacity(lines.len());
    for line in lines {
        match merged.last_mut() {
            Some(prev) if prev.time_ms == line.time_ms => {
                prev.text.push('\n');
                prev.text.push_str(&line.text);
            }
            _ => merged.push(line),
        }
    }
    merged
}

/// 把「没有时间轴的纯文本」也变成一份歌词：一行一句，时间统一为 0、`synced = false`。
///
/// 内嵌歌词（ID3 的 USLT、Vorbis 的 `LYRICS`、MP4 的 `©lyr`）很多就是这种整段文字。
/// 直接丢掉等于“这首歌没歌词”，显示出来至少还能跟着唱。
/// 纯 `[tag]` / `[mm:ss]` 行会被丢掉——那种行没有可唱的内容。
pub fn parse_plain(raw: &str) -> Lyrics {
    let lines = raw
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .filter(|line| !(line.starts_with('[') && line.ends_with(']')))
        .map(|line| LyricLine {
            time_ms: 0,
            text: line.to_string(),
            // 纯文本没有时间轴，自然也谈不上逐字。
            words: Vec::new(),
        })
        .collect();
    Lyrics {
        lines,
        ..Lyrics::default()
    }
}

/// 逐字标记的两侧括号：增强型 LRC 用尖括号，也有工具写**方括号**（`词[mm:ss.xx]`），
/// 中文圈的文件里还混得进全角括号。四种都认——认错了有「不吞字」兜底（见下）。
const WORD_MARKERS: [(char, char); 4] = [('<', '>'), ('[', ']'), ('＜', '＞'), ('［', '］')];

/// 找离行首最近的一个「可能是逐字标记」的左括号，返回
/// `(字节位置, 左括号, 它配对的右括号)`；一个左括号都没有就返回 `None`。
fn find_word_marker(rest: &str) -> Option<(usize, char, char)> {
    WORD_MARKERS
        .iter()
        .filter_map(|&(open, close)| rest.find(open).map(|at| (at, open, close)))
        .min_by_key(|&(at, ..)| at)
}

/// 把行正文按逐字标记切成 `(该段的起始时间, 文字)` 段。
///
/// 标记形式是 `<mm:ss.xx>`，也就是增强型 LRC（LRC A2 扩展）——国内外的播放器
/// （QQ 音乐、MusicBee、foobar2000 的歌词插件等）导出的逐字歌词基本都是这个写法。
/// 第一个标记**之前**的文字归这一行自己的时间戳，之后每段归该标记的时间。
///
/// 现实里的两个花样：
/// - 标记的括号还有别的写法：方括号（`[00:12.40]天气`）以及全角的那一对；
/// - 时间常常写在**词后面、甚至整句末尾**（`…そっと消える[00:13.27]`）。它是标记不是歌词，
///   剥掉之后就是一个空段、顺手丢掉——留在屏幕上就会明晃晃挂在句尾。
///
/// 底线：**不是合法时间戳的括号原样当文字**。歌词里出现「<」「[」并不罕见
/// （数学符号、`[笑]` 这类记号），宁可少认一个标记，也不能把用户看到的字吃掉。
fn split_word_timestamps(text: &str, line_time: u64) -> Vec<(u64, String)> {
    let mut segments: Vec<(u64, String)> = Vec::new();
    let mut current_time = line_time;
    let mut buffer = String::new();
    let mut rest = text;

    while let Some((open, open_char, close)) = find_word_marker(rest) {
        // 标记之前的文字先收进当前这一段。
        buffer.push_str(&rest[..open]);
        let after = &rest[open + open_char.len_utf8()..];
        // 找不到配对的右括号：从这个左括号往后都当普通文字（把 rest 清掉，免得再找一遍）。
        let Some(end) = after.find(close) else {
            buffer.push_str(&rest[open..]);
            rest = "";
            continue;
        };
        match parse_timestamp(&after[..end]) {
            Some(time_ms) => {
                // 收下这一段，从这个时间点开始新的一段。
                segments.push((current_time, std::mem::take(&mut buffer)));
                current_time = time_ms;
                rest = &after[end + close.len_utf8()..];
            }
            None => {
                // 不是时间戳（`[笑]`、`a<b` 之类）：把这个左括号当普通字符，继续往后找下一个。
                buffer.push(open_char);
                rest = after;
            }
        }
    }

    buffer.push_str(rest);
    segments.push((current_time, buffer));
    segments
}

/// 把分段变成逐字时间轴。
///
/// - 只有一段（也就是没有任何逐字标记）→ 返回空，这一行按整行高亮；
/// - 空段（`<>` 连着 `<>`）丢掉：没有字就没有“唱到哪”可言；
/// - `shift` 是「同一句被多个时间戳复用」时的整体后移量；
/// - 时间**单调不减**：逐字标记写错时不能让进度往回跳，界面上那一行会来回闪。
fn words_of(
    segments: &[(u64, String)],
    line_time: u64,
    offset_ms: i64,
    shift: i64,
) -> Vec<LyricWord> {
    if segments.len() < 2 {
        return Vec::new();
    }
    let mut words: Vec<LyricWord> = Vec::with_capacity(segments.len());
    let mut last = line_time;
    for (time_ms, text) in segments {
        if text.is_empty() {
            continue;
        }
        let shifted = (*time_ms as i64 + shift).max(0) as u64;
        let time_ms = apply_offset(shifted, offset_ms).max(last);
        last = time_ms;
        words.push(LyricWord {
            time_ms,
            text: text.clone(),
        });
    }
    words
}

fn fill_meta(line: &str, lyrics: &mut Lyrics) {
    for (tag, slot) in [
        ("ti", &mut lyrics.title),
        ("ar", &mut lyrics.artist),
        ("al", &mut lyrics.album),
    ] {
        if slot.is_none() {
            if let Some(value) = parse_tag_value(line, tag) {
                let value = value.trim();
                if !value.is_empty() {
                    *slot = Some(value.to_string());
                }
            }
        }
    }
}

fn apply_offset(time_ms: u64, offset_ms: i64) -> u64 {
    let shifted = time_ms as i64 + offset_ms;
    shifted.max(0) as u64
}

/// 取出 `[tag:value]` 形式的标签值。
fn parse_tag_value<'a>(line: &'a str, tag: &str) -> Option<&'a str> {
    let line = line.trim_start();
    let rest = line.strip_prefix('[')?;
    let end = rest.find(']')?;
    let inner = &rest[..end];
    let (key, value) = inner.split_once(':')?;
    if key.trim().eq_ignore_ascii_case(tag) {
        Some(value)
    } else {
        None
    }
}

/// 剥离行首连续的 `[mm:ss(.xx)]`，返回所有时间戳与剩余文本。
fn split_timestamps(line: &str) -> (Vec<u64>, &str) {
    let mut times = Vec::new();
    let mut rest = line;

    loop {
        let trimmed = rest.trim_start();
        let Some(after_open) = trimmed.strip_prefix('[') else {
            break;
        };
        let Some(close) = after_open.find(']') else {
            break;
        };
        let inner = &after_open[..close];
        match parse_timestamp(inner) {
            Some(ms) => {
                times.push(ms);
                rest = &after_open[close + 1..];
            }
            // 不是时间戳（例如 [ti:...]）就停止剥离。
            None => break,
        }
    }

    (times, rest)
}

/// 解析 `mm:ss` / `mm:ss.xx` / `mm:ss.xxx`。
fn parse_timestamp(inner: &str) -> Option<u64> {
    let (minutes, seconds) = inner.trim().split_once(':')?;
    let minutes: u64 = minutes.trim().parse().ok()?;

    let (secs, fraction_ms) = match seconds.trim().split_once(['.', ',']) {
        Some((s, frac)) => {
            let secs: u64 = s.trim().parse().ok()?;
            let frac = frac.trim();
            if frac.is_empty() || !frac.bytes().all(|b| b.is_ascii_digit()) {
                return None;
            }
            // `.5` = 500ms，`.50` = 500ms，`.500` = 500ms。
            let value: u64 = frac.parse().ok()?;
            let ms = match frac.len() {
                1 => value * 100,
                2 => value * 10,
                3 => value,
                n => value / 10u64.pow(n as u32 - 3),
            };
            (secs, ms)
        }
        None => (seconds.trim().parse().ok()?, 0),
    };

    // 宽进严出：秒数必须小于 60，避免把 [00:99] 这类脏数据当成时间戳。
    if secs >= 60 {
        return None;
    }
    Some(minutes * 60_000 + secs * 1_000 + fraction_ms)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_basic_timestamps() {
        let lrc = "[ti:Test Song]\n[ar:Someone]\n[00:12.50]First line\n[01:05.123]Second line\n";
        let lyrics = parse_lrc(lrc);

        assert_eq!(lyrics.title.as_deref(), Some("Test Song"));
        assert_eq!(lyrics.artist.as_deref(), Some("Someone"));
        assert_eq!(lyrics.lines.len(), 2);
        assert_eq!(lyrics.lines[0].time_ms, 12_500);
        assert_eq!(lyrics.lines[0].text, "First line");
        assert_eq!(lyrics.lines[1].time_ms, 65_123);
    }

    #[test]
    fn supports_multiple_timestamps_per_line() {
        let lyrics = parse_lrc("[00:10.00][01:20.00]Repeated chorus");
        assert_eq!(lyrics.lines.len(), 2);
        assert_eq!(lyrics.lines[0].time_ms, 10_000);
        assert_eq!(lyrics.lines[1].time_ms, 80_000);
        assert!(lyrics.lines.iter().all(|l| l.text == "Repeated chorus"));
    }

    /// 逐字（增强型 LRC）：`[mm:ss.xx]<mm:ss.xx>词<mm:ss.xx>词…`。
    #[test]
    fn parses_word_level_timeline() {
        let lyrics = parse_lrc("[00:12.00]<00:12.00>今天 <00:12.40>天气 <00:13.10>不错");
        let line = &lyrics.lines[0];

        assert_eq!(line.time_ms, 12_000);
        assert_eq!(
            line.text, "今天 天气 不错",
            "标记要剥掉，文字要连起来（词间的空格得留着）"
        );
        assert_eq!(
            line.words
                .iter()
                .map(|w| (w.time_ms, w.text.as_str()))
                .collect::<Vec<_>>(),
            vec![(12_000, "今天 "), (12_400, "天气 "), (13_100, "不错")],
            "每段的起始时间要认对"
        );
    }

    /// 没有逐字标记的行 `words` 为空——界面照旧整行高亮。
    #[test]
    fn plain_lines_have_no_words() {
        let lyrics = parse_lrc("[00:01.00]整句歌词");
        assert!(lyrics.lines[0].words.is_empty());
    }

    /// 逐字标记里的时间也要跟着 `[offset:]` 一起走。
    #[test]
    fn word_timeline_follows_global_offset() {
        let lyrics = parse_lrc("[offset:-500]\n[00:12.00]<00:12.00>甲<00:13.00>乙");
        let words = &lyrics.lines[0].words;
        assert_eq!(words[0].time_ms, 11_500);
        assert_eq!(words[1].time_ms, 12_500);
    }

    /// 同一句被多个时间戳复用时，逐字时间整体后移（第二次也得逐字亮起来）。
    #[test]
    fn word_timeline_shifts_for_repeated_line() {
        let lyrics = parse_lrc("[00:10.00][01:20.00]<00:10.00>甲<00:11.00>乙");
        assert_eq!(lyrics.lines.len(), 2);
        assert_eq!(lyrics.lines[0].words[0].time_ms, 10_000);
        assert_eq!(lyrics.lines[1].time_ms, 80_000, "第二遍从 1:20 开始");
        assert_eq!(
            lyrics.lines[1].words[0].time_ms, 80_000,
            "逐字时间要跟着这一遍的行首，而不是还停在 0:10"
        );
        assert_eq!(lyrics.lines[1].words[1].time_ms, 81_000);
    }

    /// `<` 不是时间戳时原样当文字：宁可少认一个标记，也不能把字吃掉。
    #[test]
    fn keeps_angle_brackets_that_are_not_timestamps() {
        let lyrics = parse_lrc("[00:01.00]a<b>c<00:02.00>d");
        assert_eq!(lyrics.lines[0].text, "a<b>cd");
        assert_eq!(
            lyrics.lines[0]
                .words
                .iter()
                .map(|w| (w.time_ms, w.text.as_str()))
                .collect::<Vec<_>>(),
            vec![(1_000, "a<b>c"), (2_000, "d")],
            "认不出来的尖括号原样留在文字里，只切在真正的时间标记上"
        );

        // 只有一半的尖括号也一样：整段当文字，不吞字。
        let broken = parse_lrc("[00:01.00]前半 <00:02.00");
        assert_eq!(broken.lines[0].text, "前半 <00:02.00");
        assert!(broken.lines[0].words.is_empty(), "这不是合法的逐字行");
    }

    /// 逐字时间写错（比行首还早 / 前后颠倒）时按单调不减修好，别让进度来回跳。
    #[test]
    fn clamps_word_timeline_to_be_monotonic() {
        let lyrics = parse_lrc("[00:10.00]<00:05.00>早<00:10.50>中<00:10.20>晚");
        let words = &lyrics.lines[0].words;

        assert_eq!(words[0].time_ms, 10_000, "比行首还早的按行首算");
        assert_eq!(words[1].time_ms, 10_500);
        assert_eq!(
            words[2].time_ms, 10_500,
            "倒退的那一段夹到前一段的时间上（位置不动，字照样显示）"
        );
        assert!(
            words
                .windows(2)
                .all(|pair| pair[0].time_ms <= pair[1].time_ms),
            "时间必须单调不减"
        );
    }

    /// 只有逐字标记、没有文字的行不算一句；空段（`<>` 相邻）直接丢掉。
    #[test]
    fn drops_empty_word_segments_and_empty_lines() {
        let lyrics = parse_lrc("[00:01.00]<00:01.00>\n[00:02.00]<00:02.00><00:02.50>甲");
        assert_eq!(lyrics.lines.len(), 1, "只有标记没有文字的行不该留下");
        assert_eq!(lyrics.lines[0].text, "甲");
        assert_eq!(lyrics.lines[0].words.len(), 1);
        assert_eq!(lyrics.lines[0].words[0].time_ms, 2_500);
    }

    /// 逐字标记也认方括号（有些工具写 `词[mm:ss.xx]`），**行尾**那个收尾时间同样要剥掉。
    #[test]
    fn parses_square_bracket_word_timestamps_and_masks_line_end_time() {
        let lyrics = parse_lrc("[00:10.00]今天[00:10.40]天气[00:11.00]不错[00:12.00]");
        let line = &lyrics.lines[0];

        assert_eq!(
            line.text, "今天天气不错",
            "标记不能出现在屏幕上（行尾那个也不行）"
        );
        assert_eq!(
            line.words
                .iter()
                .map(|w| (w.time_ms, w.text.as_str()))
                .collect::<Vec<_>>(),
            vec![(10_000, "今天"), (10_400, "天气"), (11_000, "不错")]
        );
    }

    /// 真实文件里两种写法常常掺在一起：逐字用 `<…>`，行尾再补一个 `[…]` 的收尾时间。
    /// 这正是用户在屏幕上看到句尾挂着 `[00:13.27]` 的那种文件。
    #[test]
    fn masks_trailing_tag_on_angle_bracket_lines() {
        let lyrics =
            parse_lrc("[00:09.93]<00:09.93>揺らめく<00:10.50>ハートそっと消える[00:13.27]");
        let line = &lyrics.lines[0];

        assert_eq!(line.time_ms, 9_930);
        assert_eq!(line.text, "揺らめくハートそっと消える");
        assert_eq!(
            line.words
                .iter()
                .map(|w| (w.time_ms, w.text.as_str()))
                .collect::<Vec<_>>(),
            vec![(9_930, "揺らめく"), (10_500, "ハートそっと消える")]
        );
    }

    /// 全角括号也认（中文圈的工具偶尔会写 `＜00:12.40＞` / `［00:12.40］`）。
    #[test]
    fn parses_full_width_word_markers() {
        let angle = parse_lrc("[00:12.00]今天＜00:12.40＞天气");
        assert_eq!(angle.lines[0].text, "今天天气");
        assert_eq!(angle.lines[0].words.len(), 2);

        let square = parse_lrc("[00:12.00]今天［00:12.40］天气");
        assert_eq!(square.lines[0].text, "今天天气");
        assert_eq!(square.lines[0].words.len(), 2);
    }

    /// 方括号这边的不吞字底线：认不出来就原样当文字（`[笑]` 不是时间戳，半个括号也不是）。
    #[test]
    fn keeps_square_brackets_that_are_not_timestamps() {
        let lyrics = parse_lrc("[00:01.00]前奏[笑]<00:02.00>开始");
        assert_eq!(lyrics.lines[0].text, "前奏[笑]开始");

        let broken = parse_lrc("[00:01.00]前半 [00:02.00");
        assert_eq!(broken.lines[0].text, "前半 [00:02.00");
        assert!(broken.lines[0].words.is_empty(), "这不是合法的逐字行");
    }

    /// 同一时间戳的译文并进 `text`，但不并进 `words`（逐字信息只属于原文）。
    #[test]
    fn translation_joins_text_but_not_words() {
        let lyrics = parse_lrc("[00:10.00]<00:10.00>原文\n[00:10.00]translation");
        let line = &lyrics.lines[0];

        assert_eq!(line.text, "原文\ntranslation");
        assert_eq!(line.words.len(), 1);
        assert_eq!(line.words[0].text, "原文");
    }

    /// 同一个时间点的两句是**同一条**（双语歌词：原文 + 翻译），文本里用换行分开。
    #[test]
    fn merges_lines_sharing_the_same_timestamp() {
        let lyrics = parse_lrc("[00:10.00]原文一句\n[00:10.00]translation\n[00:20.00]下一句\n");

        assert_eq!(lyrics.lines.len(), 2, "同一时间点的两行要合成一条");
        assert_eq!(lyrics.lines[0].time_ms, 10_000);
        assert_eq!(
            lyrics.lines[0].text, "原文一句\ntranslation",
            "文件里的先后顺序要保留：原文在前、翻译在后"
        );
        assert_eq!(lyrics.lines[1].text, "下一句");

        // 乱序也要能合上：排序之后再合并。
        let unsorted = parse_lrc("[00:30.00]b\n[00:10.00]a2\n[00:10.00]a1\n");
        assert_eq!(unsorted.lines.len(), 2);
        assert_eq!(unsorted.lines[0].text, "a2\na1", "按时间排好再合并");

        // 时间不同就不该被合并。
        assert_eq!(parse_lrc("[00:10.00]a\n[00:10.01]b\n").lines.len(), 2);
    }

    #[test]
    fn applies_global_offset_and_clamps_to_zero() {
        let lyrics = parse_lrc("[offset:-500]\n[00:00.20]Early\n[00:10.00]Later");
        assert_eq!(lyrics.offset_ms, -500);
        assert_eq!(lyrics.lines[0].time_ms, 0);
        assert_eq!(lyrics.lines[1].time_ms, 9_500);

        let positive = parse_lrc("[offset:250]\n[00:01.00]A");
        assert_eq!(positive.lines[0].time_ms, 1_250);
    }

    #[test]
    fn ignores_lines_without_timestamps_and_blank_text() {
        let lyrics = parse_lrc("just a plain line\n[00:01.00]   \n[00:02.00]Real");
        assert_eq!(lyrics.lines.len(), 1);
        assert_eq!(lyrics.lines[0].text, "Real");
    }

    #[test]
    fn rejects_out_of_range_seconds() {
        // 99 秒不是合法秒数，这行应被当成非时间戳行丢弃。
        let lyrics = parse_lrc("[00:99.00]broken");
        assert!(lyrics.is_empty());
    }

    #[test]
    fn sorted_and_active_index() {
        let lyrics = parse_lrc("[00:30.00]B\n[00:10.00]A\n[00:50.00]C");
        assert_eq!(
            lyrics
                .lines
                .iter()
                .map(|l| l.text.as_str())
                .collect::<Vec<_>>(),
            vec!["A", "B", "C"]
        );

        assert_eq!(lyrics.active_index(0), Some(0));
        assert_eq!(lyrics.active_index(10_000), Some(0));
        assert_eq!(lyrics.active_index(29_999), Some(0));
        assert_eq!(lyrics.active_index(30_000), Some(1));
        assert_eq!(lyrics.active_index(999_999), Some(2));

        assert_eq!(Lyrics::default().active_index(1_000), None);
    }

    #[test]
    fn handles_crlf_and_fraction_variants() {
        let lyrics = parse_lrc("[00:01.5]half\r\n[00:02.50]two-digit\r\n");
        assert_eq!(lyrics.lines[0].time_ms, 1_500);
        assert_eq!(lyrics.lines[1].time_ms, 2_500);
    }

    #[test]
    fn does_not_overwrite_first_metadata_value() {
        let lyrics = parse_lrc("[ti:First]\n[ti:Second]");
        assert_eq!(lyrics.title.as_deref(), Some("First"));
    }

    #[test]
    fn marks_whether_the_timeline_is_usable() {
        assert!(parse_lrc("[00:01.00]有时间的").synced);
        // 没有一行带时间戳：不算同步歌词（空歌词自然也是 false）。
        assert!(!parse_lrc("[ti:只有标签]纯文本").synced);
        assert!(!Lyrics::default().synced);
    }

    #[test]
    fn parses_plain_text_lyrics_without_timeline() {
        let lyrics = parse_plain("[ti:标签行]\n第一句\n\n  第二句  \n[00:12.00]\n");

        assert!(!lyrics.synced);
        assert_eq!(
            lyrics
                .lines
                .iter()
                .map(|line| line.text.as_str())
                .collect::<Vec<_>>(),
            vec!["第一句", "第二句"],
            "空行、纯标签行、只有时间戳没有文字的行都要丢掉"
        );
        assert!(lyrics.lines.iter().all(|line| line.time_ms == 0));
    }
}
