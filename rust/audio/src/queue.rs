//! 播放队列：只回答“下一首是谁”，不碰解码也不碰声卡。
//!
//! 把顺序规则收在这里的好处是：快进/快退/自动续播/循环/随机这些最容易写错的边界
//! 都能在宿主机上直接单测，不需要任何音频设备。

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

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
    ///
    /// **随机播放不影响它**：随机管的是「下一首是谁」，而自然播完时根本没有「下一首」
    /// 这回事——那就重复这一首。想「一轮之内不重复地放完整个列表」，把循环切到
    /// **列表循环**（那是它本来的一档），别指望单曲循环替它办。
    One,
}

impl RepeatMode {
    /// 编码：`0` 关 / `1` 列表循环 / `2` 单曲循环。
    ///
    /// 这个编码是**跨层约定**，几处都靠它对齐，要改就得一起改：
    /// - 通知栏 / 桌面小部件的按钮（`playback_bridge.rs` 的 `REPEAT_*` 常量，
    ///   以及 Kotlin 侧的 `PlaybackBridge.REPEAT_*`）
    /// - 引擎快照里那个 `AtomicU8`
    /// - 退出应用时落库的那份设置（`musicplayer-core` 的 `meta` 表）
    pub fn code(self) -> u8 {
        match self {
            Self::Off => 0,
            Self::All => 1,
            Self::One => 2,
        }
    }

    /// 解码；认不出来的值一律当「关」。
    ///
    /// 老库、手改过的库、以及将来多加一档模式之后的旧客户端都会走到这条兜底上——
    /// 「循环模式认不出来」绝不该让播放起不来。
    pub fn from_code(code: u8) -> Self {
        match code {
            1 => Self::All,
            2 => Self::One,
            _ => Self::Off,
        }
    }
}

/// 随机播放用的小随机数发生器（xorshift64*）。
///
/// 不为这点需求引入 `rand`：只需要「从候选里挑一个」，均匀性绰绰有余、零依赖，
/// 而且能用固定种子写出确定性测试（见 [`Rng::seeded`]）。
#[derive(Debug, Clone)]
struct Rng {
    state: u64,
}

/// 同一纳秒内创建多个队列时用来错开种子，保证它们的随机序列不一样。
static SEED_COUNTER: AtomicU64 = AtomicU64::new(0);

impl Rng {
    /// 时间 + 进程内自增计数做种子（计数器保证同纳秒创建的也不会拿到同一条序列）。
    fn from_entropy() -> Self {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|elapsed| elapsed.as_nanos() as u64)
            .unwrap_or(0);
        let counter = SEED_COUNTER.fetch_add(1, Ordering::Relaxed);
        Self::seeded(nanos ^ counter.wrapping_mul(0x9E37_79B9_7F4A_7C15))
    }

    /// 固定种子：给测试用，让「一轮内不重复」这类性质可复现。
    fn seeded(seed: u64) -> Self {
        // xorshift 的状态不能是 0（会一直输出 0），换一个非零常量顶上。
        Self {
            state: if seed == 0 {
                0x1234_5678_9ABC_DEF0
            } else {
                seed
            },
        }
    }

    fn next_u64(&mut self) -> u64 {
        let mut x = self.state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.state = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    /// `[0, bound)` 中的值；`bound` 必须大于 0。
    ///
    /// 取模带来的偏差只在 bound 很大时才明显，播放队列最多几千首，可以忽略。
    fn below(&mut self, bound: usize) -> usize {
        debug_assert!(bound > 0);
        (self.next_u64() % bound as u64) as usize
    }
}

impl Default for Rng {
    fn default() -> Self {
        Self::from_entropy()
    }
}

/// 播放队列。
#[derive(Debug, Default, Clone)]
pub struct PlayQueue {
    items: Vec<QueueItem>,
    /// 当前下标；空队列时为 0（配合 `items.is_empty()` 判断有效性）。
    index: usize,
    repeat: RepeatMode,
    /// 随机播放开关。它与循环模式是两个独立的维度：
    /// 随机决定「下一首是谁」，循环决定「一轮放完怎么办」。
    shuffle: bool,
    /// 本轮随机播放已经放过的下标（含当前这首），按实际播放顺序排列。
    /// 顺序播放时不维护它；随机播放下的「上一首」也只能靠它回退。
    played: Vec<usize>,
    rng: Rng,
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
        // 换了队列就是新的一轮：随机播放的「先放过的」记录必须跟着清掉。
        self.start_cycle();
    }

    /// 重开一轮随机播放：把当前这首记为「本轮唯一放过的」。
    ///
    /// 这样刚打开随机播放就点「下一首」时，不会又抽回正在放的这一首。
    fn start_cycle(&mut self) {
        self.played.clear();
        if self.shuffle && !self.items.is_empty() {
            self.played.push(self.index);
        }
    }

    /// 把当前下标记进本轮的播放历史（随机播放的「上一首」靠它回退）。
    fn record_played(&mut self) {
        if self.shuffle && self.played.last() != Some(&self.index) {
            self.played.push(self.index);
        }
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

    pub fn shuffle(&self) -> bool {
        self.shuffle
    }

    /// 打开 / 关闭随机播放。
    ///
    /// 打开时把当前这首当作本轮的起点；关闭时当前下标不动，接着按顺序往后走。
    pub fn set_shuffle(&mut self, on: bool) {
        self.shuffle = on;
        self.start_cycle();
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
        self.record_played();
        self.current()
    }

    /// 下一首。
    ///
    /// `auto = true` 表示“当前这首自然播完了”，此时才应用单曲循环；
    /// `auto = false` 表示用户主动点了下一首，即便在单曲循环下也应该换歌。
    ///
    /// **随机播放不改变这条规则**：随机只决定「下一首是谁」，而自然播完时压根没有
    /// 「下一首」这回事——单曲循环就是把这一首再放一遍。原来随机开着时会把单曲循环
    /// 顶掉（改成按列表循环走），理由是不想「把列表里别的歌锁在门外」；但那个行为
    /// 本来就有自己的一档（「随机 + 列表循环」），按钮上写「单曲循环」就该循环这一首，
    /// 否则用户只会觉得这个按钮坏了。
    pub fn advance(&mut self, auto: bool) -> Option<&QueueItem> {
        if self.items.is_empty() {
            return None;
        }
        if auto && self.repeat == RepeatMode::One {
            return self.current();
        }
        if self.shuffle {
            return self.advance_shuffled();
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

    /// 随机播放的「下一首」。
    ///
    /// 从**本轮还没放过的**曲目里抽一首——随机播放的完整语义就是「一轮之内不重复」。
    /// 一轮放完时再看循环模式：**只要循环不是「关闭」就重开一轮**——随机的“一轮”
    /// 里每首都只放一次，所以走到轮末时「列表循环」与「单曲循环」都是同一件事
    /// （单曲循环只在**自然播完**时生效，见 [`PlayQueue::advance`]；能走到轮末说明是
    /// 用户手动点的「下一首」）；否则返回 `None`（与顺序播放「播完最后一首就停」一致）。
    fn advance_shuffled(&mut self) -> Option<&QueueItem> {
        // 回退过的历史里可能已经没有当前这首了，先记回去：
        // 否则「上一首」会在回退一次之后就突然断掉。
        self.record_played();
        let mut candidates: Vec<usize> = (0..self.items.len())
            .filter(|&i| i != self.index && !self.played.contains(&i))
            .collect();
        if candidates.is_empty() {
            // 只有「关闭」才停：列表循环 / 单曲循环都重开一轮——列表放完自动接着放。
            if self.repeat == RepeatMode::Off {
                return None;
            }
            // 重开一轮：当前这首算已放过，其余重新进入候选。
            self.played.clear();
            self.played.push(self.index);
            if self.items.len() == 1 {
                // 队列里只有这一首：列表循环下留在原地继续放。
                return self.current();
            }
            candidates = (0..self.items.len()).filter(|&i| i != self.index).collect();
        }
        let next = candidates[self.rng.below(candidates.len())];
        self.index = next;
        self.played.push(next);
        self.current()
    }

    /// 上一首；已经在第一首时返回 `None`（由调用方决定是否“回到开头”）。
    pub fn rewind(&mut self) -> Option<&QueueItem> {
        if self.items.is_empty() {
            return None;
        }
        if self.shuffle {
            return self.rewind_shuffled();
        }
        if self.index == 0 {
            return None;
        }
        self.index -= 1;
        self.current()
    }

    /// 随机播放的「上一首」：随机没有固定顺序，只能顺着本轮的播放历史往回走。
    /// 历史见底就返回 `None`（调用方按惯例回到本曲开头）。
    fn rewind_shuffled(&mut self) -> Option<&QueueItem> {
        // 历史末位通常就是当前这首，先弹掉它，拿到的才是真正的「上一首」。
        if self.played.last() == Some(&self.index) {
            self.played.pop();
        }
        let previous = self.played.pop()?;
        self.index = previous;
        self.current()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 循环模式的编码是**跨层约定**：0 关 / 1 列表 / 2 单曲，认不出来的一律当关。
    #[test]
    fn repeat_mode_codes_round_trip() {
        assert_eq!(RepeatMode::Off.code(), 0);
        assert_eq!(RepeatMode::All.code(), 1);
        assert_eq!(RepeatMode::One.code(), 2);
        for mode in [RepeatMode::Off, RepeatMode::All, RepeatMode::One] {
            assert_eq!(RepeatMode::from_code(mode.code()), mode, "编解码要能对上");
        }
        // 老库 / 手改过的库 / 以后多加一档模式之后的旧客户端：认不出来不能把播放搞崩。
        assert_eq!(RepeatMode::from_code(9), RepeatMode::Off);
    }

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

    // -----------------------------------------------------------------------
    // 随机播放
    // -----------------------------------------------------------------------

    /// 打开随机开关并固定种子：随机用例里的「随机」必须可复现。
    fn shuffled(names: &[&str], seed: u64) -> PlayQueue {
        let mut q = queue_of(names);
        q.rng = Rng::seeded(seed);
        q.set_shuffle(true);
        q
    }

    #[test]
    fn shuffle_plays_every_track_once_per_cycle() {
        let mut q = shuffled(&["a", "b", "c", "d"], 0x5EED);

        let mut seen = vec![q.current().expect("队列非空").id];
        for _ in 0..3 {
            let id = q.advance(false).expect("一轮还没放完，应该还有下一首").id;
            assert!(!seen.contains(&id), "一轮之内不该重复放：{id}");
            seen.push(id);
        }
        assert_eq!(seen.len(), 4, "一轮应该把四首都放一遍");

        // 一轮放完 + 循环关闭：停下来（与顺序播放的语义一致）。
        assert!(q.advance(false).is_none());
    }

    #[test]
    fn shuffle_starts_new_cycle_when_repeat_all() {
        let mut q = shuffled(&["a", "b", "c"], 7);
        q.set_repeat(RepeatMode::All);

        assert!(q.advance(false).is_some());
        assert!(q.advance(false).is_some(), "三首刚好放完一轮");

        let current = q.current().expect("队列非空").id;
        let next = q.advance(false).expect("列表循环下应该重开一轮").id;
        assert_ne!(next, current, "重开一轮时不该又抽到当前这首");
    }

    #[test]
    fn shuffle_keeps_single_repeat_on_natural_end() {
        let mut q = shuffled(&["a", "b", "c"], 11);
        q.set_repeat(RepeatMode::One);

        let current = q.current().expect("队列非空").id;
        // 自然播完：随机下也要留在原地——「单曲循环」就是这一首再放一遍，
        // 随机只决定「下一首是谁」，而这里没有「下一首」这回事。
        for _ in 0..3 {
            assert_eq!(q.advance(true).map(|i| i.id), Some(current));
            assert_eq!(q.index(), 0, "位置不该动");
        }

        // 手动点下一首：仍然随机换歌（与顺序播放下的单曲循环一致）。
        assert_ne!(q.advance(false).map(|i| i.id), Some(current));
    }

    #[test]
    fn shuffle_restarts_cycle_on_manual_next_when_repeat_one() {
        let mut q = shuffled(&["a", "b"], 23);
        q.set_repeat(RepeatMode::One);

        // 手动「下一首」也能把一轮走完（auto = false 只是不应用单曲循环）。
        q.advance(false).expect("本轮还有别的歌");
        // 一轮放完：接着重开一轮，而不是停下。
        assert!(q.advance(false).is_some(), "循环开着就不该停在轮末");
    }

    #[test]
    fn shuffle_never_replays_current_track() {
        // 只有一首：关闭循环时随机也没有别的可放，就此停下。
        let mut q = shuffled(&["only"], 3);
        assert!(q.advance(false).is_none());

        // 列表循环下留在原地继续放。
        q.set_repeat(RepeatMode::All);
        assert_eq!(q.advance(false).map(|i| i.id), Some(1));
    }

    #[test]
    fn shuffle_rewind_walks_back_through_play_history() {
        let mut q = shuffled(&["a", "b", "c", "d"], 42);

        let first = q.current().expect("队列非空").id;
        let second = q.advance(false).expect("还有下一首").id;
        q.advance(false).expect("还有下一首");

        assert_eq!(q.rewind().map(|i| i.id), Some(second));
        assert_eq!(q.rewind().map(|i| i.id), Some(first));
        assert!(q.rewind().is_none(), "本轮开头之前没有上一首");
        assert_eq!(q.current().map(|i| i.id), Some(first));

        // 回退之后再往前：至少不会是当前这首。
        let again = q.advance(false).expect("还有下一首").id;
        assert_ne!(again, first);
        assert_eq!(q.rewind().map(|i| i.id), Some(first));
    }

    #[test]
    fn turning_shuffle_off_resumes_sequential_order() {
        let mut q = shuffled(&["a", "b", "c"], 99);
        q.advance(false);
        let index = q.index();

        q.set_shuffle(false);
        assert_eq!(q.index(), index, "关掉随机不该改变当前曲目");
        // id 是「下标 + 1」：下一个下标对应的 id 就是 index + 2。
        let expected = if index + 1 < q.len() {
            Some(index as i64 + 2)
        } else {
            None
        };
        assert_eq!(
            q.advance(false).map(|i| i.id),
            expected,
            "之后按原顺序往后走"
        );
    }

    #[test]
    fn replace_resets_shuffle_cycle() {
        let mut q = shuffled(&["a", "b", "c"], 5);
        q.advance(false);
        q.advance(false); // 一轮放完

        // 换一批歌：新的一轮，当前这首是起点（上一轮的历史必须清掉）。
        q.replace(vec![QueueItem::new(9, "/m/x.mp3")], 0);
        assert_eq!(q.played, vec![0]);
    }

    #[test]
    fn rng_seed_zero_still_produces_values() {
        // 种子 0 是 xorshift 的死点，构造时必须换掉，否则永远输出同一个值。
        let mut rng = Rng::seeded(0);
        let first = rng.next_u64();
        assert_ne!(first, 0);
        assert_ne!(rng.next_u64(), first);
    }
}
