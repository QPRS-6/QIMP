#!/bin/bash
# 生成测试用的小体积样本（1 秒 440Hz 正弦，单声道 16kHz）。
set -euo pipefail
# 用脚本自己所在的位置定位，不写死绝对路径：仓库目录改个名（比如这次改成 QIMP）
# 也不至于把脚本弄坏。
cd "$(dirname "${BASH_SOURCE[0]}")/.."
mkdir -p testdata
ffmpeg -hide_banner -v error -f lavfi -i "sine=frequency=440:duration=1" \
  -ac 1 -ar 16000 -c:a libvorbis -q:a 1 -y testdata/ogg_vorbis.ogg
ffmpeg -hide_banner -v error -f lavfi -i "sine=frequency=440:duration=1" \
  -ac 1 -ar 16000 -c:a libopus -b:a 24k -y testdata/ogg_opus.ogg
# 「没下完」的 mp3：头部（含 Xing 时长表）完整、数据只留一半。
# 用户库里这类文件很常见（下载中断、拷贝被打断、从坏卡里拷出来的）：
# 时长显示 4 秒，实际只有 2 秒的音频数据。
ffmpeg -hide_banner -v error -f lavfi -i "sine=frequency=440:duration=4" \
  -ac 1 -ar 16000 -c:a libmp3lame -b:a 32k -y testdata/truncated.mp3
size=$(wc -c < testdata/truncated.mp3)
head -c "$((size / 2))" testdata/truncated.mp3 > testdata/truncated.mp3.tmp
mv testdata/truncated.mp3.tmp testdata/truncated.mp3
ls -la testdata/
file testdata/*.ogg testdata/*.mp3
