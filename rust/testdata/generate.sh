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
ls -la testdata/
file testdata/*.ogg
