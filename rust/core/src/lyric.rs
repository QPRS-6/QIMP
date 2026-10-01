//! LRC 歌词解析。
//!
//! 支持：
//! - `[mm:ss]` / `[mm:ss.xx]` / `[mm:ss.xxx]` 三种时间精度
//! - 一行多时间戳（`[00:10.00][01:20.00]同一句`）
//! - `[offset:-500]` 全局偏移（毫秒，正数表示歌词提前）
//! - `[ti:]` `[ar:]` `[al:]` 等元信息标签（忽略但不报错）
//! - CRLF 换行、无时间戳的纯文本行（跳过）

use serde::{Deserialize, Serialize};

/// 一条带时间轴的歌词。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LyricLine {
    /// 起始时间（毫秒，已应用 offset）。
    pub time_ms: u64,
    pub text: String,
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
        let text = text.trim().to_string();
        if text.is_empty() {
            continue;
        }
        for time_ms in times {
            lyrics.lines.push(LyricLine {
                time_ms: apply_offset(time_ms, offset_ms),
                text: text.clone(),
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
        })
        .collect();
    Lyrics {
        lines,
        ..Lyrics::default()
    }
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
