//! 用真实音乐文件抽查跳转落点精度（默认不跑，需要显式指定文件）。
//!
//! 为什么需要：symphonia 的 `SeekMode::Accurate` 只能跳到**不晚于**目标的那一包，
//! 不同容器 / 编码的包长差别很大（mp3 一帧约 26ms，flac 一块可能上百毫秒，
//! 某些容器只给粗粒度索引）。UI 上「跳转后锁住目标位置」的容差是按这个误差定的，
//! 所以必须能对着真文件量一量，而不是只看自己造的 WAV。
//!
//! ```bash
//! MUSIC_FILE=/tmp/song.mp3 cargo test -p musicplayer-audio --test real_file_seek -- --ignored --nocapture
//! ```
//!
//! 没设 `MUSIC_FILE` 时整组用例直接跳过。

use musicplayer_audio::AudioDecoder;

/// 相对时长的抽样点：头 / 中 / 尾（尾部的索引最容易出问题）。
const RATIOS: [f64; 5] = [0.02, 0.25, 0.5, 0.75, 0.98];

fn music_file() -> Option<String> {
    match std::env::var("MUSIC_FILE") {
        Ok(path) if !path.is_empty() => Some(path),
        _ => {
            eprintln!("跳过：没有设置 MUSIC_FILE");
            None
        }
    }
}

/// 把文件解到底，返回「实际解出来的时长（毫秒）」与「解码为什么停下」。
///
/// 文件可能是坏的 / 被截断的（手机上的音乐库很常见），这时要能报出**解码到哪儿为止**，
/// 而不是直接 panic——否则既看不出问题在哪，也没法继续量跳转精度。
fn scan_duration(decoder: &mut AudioDecoder) -> (u64, Option<String>) {
    let info = decoder.info();
    let channels = u64::from(info.channels.max(1));
    let sample_rate = u64::from(info.sample_rate.max(1));
    let mut total_ms = 0u64;
    loop {
        match decoder.next_chunk() {
            Ok(Some(chunk)) => {
                let frames = chunk.len() as u64 / channels;
                total_ms += frames * 1000 / sample_rate;
            }
            Ok(None) => return (total_ms, None),
            Err(err) => return (total_ms, Some(err.to_string())),
        }
    }
}

/// 量一下各抽样点的落点误差，并打印出来。
#[test]
#[ignore = "需要 MUSIC_FILE 指向真实音频文件"]
fn seek_accuracy_on_real_file() {
    let Some(path) = music_file() else { return };
    let mut decoder = AudioDecoder::open(&path).expect("打开文件");
    let info = decoder.info();
    eprintln!("文件：{path}");
    eprintln!("格式：{} Hz / {} 声道", info.sample_rate, info.channels);

    // 先走到文件尾，量出真实时长（容器声明的时长不一定准）。
    let (total_ms, stopped) = scan_duration(&mut decoder);
    match &stopped {
        None => eprintln!("时长约 {total_ms} ms（完整解码）"),
        Some(err) => eprintln!("时长约 {total_ms} ms（解码中断：{err}，文件可能已损坏）"),
    }
    assert!(total_ms > 0, "一首都没解出来，没法量跳转：{stopped:?}");

    let mut worst = 0i64;
    let mut measured = 0;
    for ratio in RATIOS {
        let target = (total_ms as f64 * ratio) as u64;
        match decoder.seek(target) {
            Ok(actual) => {
                let delta = actual as i64 - target as i64;
                worst = worst.max(delta.abs());
                measured += 1;
                eprintln!("  目标 {target:>8} ms → 实际 {actual:>8} ms（差 {delta:>6} ms）");
            }
            // 坏文件里的区域可能根本跳不进去；这属于文件问题，不算精度问题。
            Err(err) => eprintln!("  目标 {target:>8} ms → 跳转失败：{err}"),
        }
    }
    assert!(measured > 0, "一次跳转都没成功");

    // UI 的容差是 400ms：真文件明显超了就得回来调那个常量。
    assert!(
        worst <= 400,
        "跳转误差最大 {worst} ms，超过 UI 容差；请调整 now_playing_bar.dart 里的 _seekToleranceMs"
    );
    // 顺带确认跳转不是“原地不动”。
    if decoder.seek(0).is_ok() {
        eprintln!("  跳回开头成功");
    }
}
