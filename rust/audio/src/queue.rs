//! 播放队列：只回答“下一首是谁”，不碰解码也不碰声卡。
//!
//! 把顺序规则收在这里的好处是：快进/快退/自动续播/循环这些最容易写错的边界
//! 都能在宿主机上直接单测，不需要任何音频设备。

use musicplayer_core::models::TrackId;

/// 队列里的一项：曲库 id（用于回查元数据）+ 播放要用的绝对路径。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QueueItem {
    pub id: TrackId,
    pub path: String,
}

impl QueueItem {
    pub fn new(id: TrackId, path: impl Into<String>) -> Self {
        Self {
            id,
            path: path.into(),
        }
    }
}

/// 循环方式。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum RepeatMode {
    /// 播完最后一首就停。
    #[default]
    Off,
    /// 播完最后一首回到第一首。
    All,
    /// 单曲循环（只在“自然播完”时生效，用户手动点下一首仍然换歌）。
    One,
}

/// 播放队列。
#[derive(Debug, Default, Clone)]
pub struct PlayQueue {
    items: Vec<QueueItem>,
    /// 当前下标；空队列时为 0（配合 `items.is_empty()` 判断有效性）。
    index: usize,
    repeat: RepeatMode,
}

impl PlayQueue {
    pub fn new() -> Self {
        Self::default()
    }

    /// 整体替换队列。`start_at` 越界时会被夹到合法范围。
    pub fn replace(&mut self, items: Vec<QueueItem>, start_at: usize) {
        self.index = if items.is_empty() {
            0
        } else {
            start_at.min(items.len() - 1)
        };
        self.items = items;
    }

    pub fn items(&self) -> &[QueueItem] {
        &self.items
    }

    pub fn len(&self) -> usize {
        self.items.len()
    }

    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }

    pub fn index(&self) -> usize {
        self.index
    }

    pub fn repeat(&self) -> RepeatMode {
        self.repeat
    }

    pub fn set_repeat(&mut self, repeat: RepeatMode) {
        self.repeat = repeat;
    }

    pub fn current(&self) -> Option<&QueueItem> {
        self.items.get(self.index)
    }

    /// 直接跳到第 `index` 项；越界返回 `None`。
    pub fn select(&mut self, index: usize) -> Option<&QueueItem> {
        if index >= self.items.len() {
            return None;
        }
        self.index = index;
        self.current()
    }

    /// 下一首。
    ///
    /// `auto = true` 表示“当前这首自然播完了”，此时才应用单曲循环；
    /// `auto = false` 表示用户主动点了下一首，即便在单曲循环下也应该换歌。
    pub fn advance(&mut self, auto: bool) -> Option<&QueueItem> {
        if self.items.is_empty() {
            return None;
        }
        if auto && self.repeat == RepeatMode::One {
            return self.current();
        }
        if self.index + 1 < self.items.len() {
            self.index += 1;
            return self.current();
        }
        // 已经在最后一首
        if self.repeat == RepeatMode::All {
            self.index = 0;
            return self.current();
        }
        None
    }

    /// 上一首；已经在第一首时返回 `None`（由调用方决定是否“回到开头”）。
    pub fn rewind(&mut self) -> Option<&QueueItem> {
        if self.items.is_empty() {
            return None;
        }
        if self.index == 0 {
            return None;
        }
        self.index -= 1;
        self.current()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn queue_of(names: &[&str]) -> PlayQueue {
        let items = names
            .iter()
            .enumerate()
            .map(|(i, n)| QueueItem::new(i as TrackId + 1, format!("/m/{n}.flac")))
            .collect();
        let mut q = PlayQueue::new();
        q.replace(items, 0);
        q
    }

    #[test]
    fn replace_clamps_start_index() {
        let mut q = queue_of(&["a", "b"]);
        q.replace(vec![QueueItem::new(9, "/m/x.mp3")], 42);
        assert_eq!(q.index(), 0);
        assert_eq!(q.current().map(|i| i.id), Some(9));
    }

    #[test]
    fn advance_stops_at_end_when_repeat_off() {
        let mut q = queue_of(&["a", "b"]);
        assert_eq!(q.advance(false).map(|i| i.id), Some(2));
        assert!(q.advance(false).is_none(), "最后一首之后不应有下一首");
    }

    #[test]
    fn advance_wraps_when_repeat_all() {
        let mut q = queue_of(&["a", "b"]);
        q.set_repeat(RepeatMode::All);
        assert_eq!(q.advance(false).map(|i| i.id), Some(2));
        assert_eq!(q.advance(false).map(|i| i.id), Some(1), "应回到第一首");
    }

    #[test]
    fn repeat_one_only_applies_to_natural_end() {
        let mut q = queue_of(&["a", "b"]);
        q.set_repeat(RepeatMode::One);

        // 手动下一首：仍然换歌
        assert_eq!(q.advance(false).map(|i| i.id), Some(2));

        // 自然播完：留在原地
        assert_eq!(q.advance(true).map(|i| i.id), Some(2));
        assert_eq!(q.index(), 1);
    }

    #[test]
    fn select_out_of_range_is_rejected() {
        let mut q = queue_of(&["a"]);
        assert!(q.select(5).is_none());
        assert_eq!(q.index(), 0, "失败的 select 不应改动下标");
        assert_eq!(q.select(0).map(|i| i.id), Some(1));
    }

    #[test]
    fn rewind_stops_at_first_item() {
        let mut q = queue_of(&["a", "b", "c"]);
        assert!(q.rewind().is_none(), "第一首之前没有上一首");
        q.select(2);
        assert_eq!(q.rewind().map(|i| i.id), Some(2));
        assert_eq!(q.rewind().map(|i| i.id), Some(1));
        assert!(q.rewind().is_none());
    }

    #[test]
    fn empty_queue_never_yields_items() {
        let mut q = PlayQueue::new();
        assert!(q.is_empty());
        assert!(q.current().is_none());
        assert!(q.advance(true).is_none());
        assert!(q.rewind().is_none());
    }
}
