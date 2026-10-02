#!/usr/bin/env bash
# 一键构建 Android APK：先把 Rust 编成各 ABI 的 .so，再交给 Flutter 打包。
#
# 为什么需要这个脚本：Rust 侧走的是“手动 jniLibs”方案（没有用 flutter_rust_bridge
# 默认的 cargokit 插件），所以 `flutter build apk` 不会自己编译 Rust。
# 忘记先编 .so 的后果是：APK 能装能开，但一调用 FFI 就崩。
#
# 一次打两种产物：
#   app-<abi>-<mode>.apk   按 ABI 分开：每个只带自己那一份 .so，体积最小 —— **手机装这个**
#   app-<mode>.apk         universal：三个 ABI 都在里面，给不确定机型 / 分发给别人用
#
# 用法：
#   scripts/build-apk.sh              # debug APK（默认）
#   scripts/build-apk.sh --release    # release APK
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="${ANDROID_HOME:-$HOME/Android/Sdk}"
export ANDROID_HOME="$SDK"
# 版本号与 Flutter 3.47.5 期望的一致（FlutterExtension.kt 里的 ndkVersion）
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$SDK/ndk/28.2.13676358}"
export PATH="$HOME/.cargo/bin:$PATH"

# Flutter 默认打这三个 ABI；少编任何一个，对应机型上都会因找不到 .so 而崩溃。
ABIS=(armeabi-v7a arm64-v8a x86_64)
TARGETS=()
for abi in "${ABIS[@]}"; do
  TARGETS+=(-t "$abi")
done

if [[ ! -x "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" ]]; then
  echo "找不到 NDK：$ANDROID_NDK_HOME" >&2
  echo "请先安装（无需 sudo）：sdkmanager --install \"ndk;28.2.13676358\"" >&2
  exit 1
fi

# 交叉编译需要对应的 Rust std，缺了会报 “can't find crate for `core`”，先自查避免看不懂的报错
if command -v rustup >/dev/null 2>&1; then
  for target in armv7-linux-androideabi aarch64-linux-android x86_64-linux-android; do
    if ! rustup target list --installed | grep -qx "$target"; then
      echo "缺少 Rust 目标：$target" >&2
      echo "请执行：rustup target add $target" >&2
      exit 1
    fi
  done
fi

echo "==> [1/2] 编译 Rust：${ABIS[*]}"
(
  cd "$ROOT/rust"
  cargo ndk "${TARGETS[@]}" -o "$ROOT/app/android/app/src/main/jniLibs" \
    build --release -p musicplayer-ffi
)

MODE="${1:---debug}"
FLUTTER_MODE="${MODE#--}"
OUT="$ROOT/app/build/app/outputs/flutter-apk"

# 按 ABI 分开打：每个 APK 只带自己那一份 .so（libflutter + libapp + libmusicplayer_ffi
# 各一份就有十几 MB，三个 ABI 全塞进一个包，等于让每台手机白背另外两份）。
# 两种产物的文件名不一样，互不覆盖，可以共存于同一个输出目录。
echo "==> [2/3] 按 ABI 分开打包：${ABIS[*]}"
(
  cd "$ROOT/app"
  flutter build apk "$MODE" --split-per-abi
)

echo "==> [3/3] 再打一份 universal（三个 ABI 都带）"
(
  cd "$ROOT/app"
  flutter build apk "$MODE"
)

echo
echo "完成。产物：$OUT"
ls -la "$OUT" | grep -i '\.apk' || true
echo
echo "手机装对应的那一份即可（大多数手机是 arm64-v8a）："
echo "  adb install -r $OUT/app-arm64-v8a-$FLUTTER_MODE.apk"
