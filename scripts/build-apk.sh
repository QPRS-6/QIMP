#!/usr/bin/env bash
# 一键构建 Android APK：先把 Rust 编成各 ABI 的 .so，再交给 Flutter 打包。
#
# 为什么需要这个脚本：Rust 侧走的是“手动 jniLibs”方案（没有用 flutter_rust_bridge
# 默认的 cargokit 插件），所以 `flutter build apk` 不会自己编译 Rust。
# 忘记先编 .so 的后果是：APK 能装能开，但一调用 FFI 就崩。
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
echo "==> [2/2] 打包 APK：$MODE"
(
  cd "$ROOT/app"
  flutter build apk "$MODE"
)

echo
echo "完成。产物：$ROOT/app/build/app/outputs/flutter-apk/"
ls -la "$ROOT/app/build/app/outputs/flutter-apk/" | grep -i '\.apk' || true
