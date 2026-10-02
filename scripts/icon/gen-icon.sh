#!/usr/bin/env bash
# 由 scripts/icon/qimp-icon.svg 生成 Android 侧的全部图标资源：
#
#   res/mipmap-*/ic_launcher.png             传统图标：白底 + 粉色圈与音符（48 / 72 / 96 / 144 / 192）
#   res/mipmap-*/ic_launcher_foreground.png  自适应图标的前景：透明底，整个图案缩进安全区
#
# 为什么要有这个脚本：图标是「一张稿子 + 一份生成产物」，手改 PNG 的话，下一档密度就会长歪。
# 稿子只有 qimp-icon.svg 一份（透明底），白底是生成传统图标时刷上去的
# —— 自适应图标的前景得是透明的，底色交给 mipmap-anydpi-v26 里的 background 层。
#
# 用法：scripts/icon/gen-icon.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SVG="$ROOT/scripts/icon/qimp-icon.svg"
RES="$ROOT/app/android/app/src/main/res"

command -v rsvg-convert >/dev/null || { echo "缺 rsvg-convert（pacman -S librsvg）" >&2; exit 1; }
command -v magick >/dev/null || { echo "缺 ImageMagick" >&2; exit 1; }

# 传统图标的边长（mdpi 48 起，一档 1.5 倍）与自适应图标画布的边长（108dp 起，同样 1.5 倍）。
# 两者比例固定：自适应画布 = 图标边长 × 2.25。别各写一套数字。
DENSITIES=(mdpi hdpi xhdpi xxhdpi xxxhdpi)
LEGACY=(48 72 96 144 192)

# 自适应图标：画布 108dp 里只有中间那段是「一定看得见」的（外面 18dp 会被各种形状的蒙版裁掉或
# 拿去视差）。所以图案不能照传统图标那样顶到边，得整个缩进安全区里。
SAFE=66   # 图案（也就是那圈外环）在 108dp 画布上占多少 dp

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 透明底的高分辨率原稿：先在 1254（稿子自己的尺寸）渲染出来，再裁到图案边界
rsvg-convert -w 1254 -h 1254 -b none "$SVG" -o "$TMP/art.png"
magick "$TMP/art.png" -trim +repage "$TMP/art_trim.png"

for i in "${!DENSITIES[@]}"; do
  d="${DENSITIES[$i]}"
  size="${LEGACY[$i]}"
  fg=$((size * 108 / 48))        # 自适应画布边长
  art=$((fg * SAFE / 108))       # 图案在画布上的边长

  out="$RES/mipmap-$d"
  mkdir -p "$out"

  # 传统图标：白底（与稿子的底色一致），图案按原样铺满画布
  rsvg-convert -w "$size" -h "$size" -b white "$SVG" -o "$out/ic_launcher.png"

  # 前景：裁到图案边界后等比缩放、居中贴到透明画布上
  magick "$TMP/art_trim.png" -resize "${art}x${art}" \
    -background none -gravity center -extent "${fg}x${fg}" \
    "$out/ic_launcher_foreground.png"

  printf '  mipmap-%-8s ic_launcher.png %sx%s   ic_launcher_foreground.png %sx%s（图案 %s）\n' \
    "$d" "$size" "$size" "$fg" "$fg" "$art"
done

echo "完成。清单：$RES/mipmap-*/"
