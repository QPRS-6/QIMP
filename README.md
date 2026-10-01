# ro.qprs.musicplayer

Android 端**纯本地**音乐播放器：Rust 负责全部逻辑（扫描 / 元数据 / 索引 / 歌词），Flutter 只负责界面。

## 目录结构

| 路径 | 说明 |
| --- | --- |
| `rust/core/` | 核心库，纯 Rust、不依赖 Android，可在宿主机直接 `cargo test` |
| `rust/ffi/` | FFI 边界层，绑定由 flutter_rust_bridge 生成 |
| `app/` | Flutter 应用（Android 平台） |
| `scripts/build-apk.sh` | 一键构建 APK：先编 Rust 成 `.so`，再交给 `flutter build apk` |

## 本机环境（已配置好）

| 组件 | 位置 / 版本 |
| --- | --- |
| Flutter | 3.47.5（Arch `flutter-bin`，SDK 经 unionfs 暴露在 `~/.cache/flutter_sdk`） |
| Android SDK | `$HOME/Android/Sdk`（已写入 `flutter config --android-sdk`） |
| NDK | `28.2.13676358`（与 Flutter 3.47.5 期望值一致） |
| JDK | Zulu 21（已写入 `flutter config --jdk-dir`） |
| Rust | 1.98.1，目标 `aarch64-linux-android` / `armv7-linux-androideabi` / `x86_64-linux-android` |

环境变量不是必须的（CI 之外），脚本会自己设置 `ANDROID_HOME` / `ANDROID_NDK_HOME`。
若想让交互式终端也能直接跑 `cargo ndk`，可在 fish 配置里加：

```fish
set -gx ANDROID_HOME $HOME/Android/Sdk
set -gx ANDROID_NDK_HOME $HOME/Android/Sdk/ndk/28.2.13676358
set -gx JAVA_HOME /usr/lib/jvm/zulu-21
fish_add_path $HOME/.cargo/bin
```

## 常用命令

```bash
# Rust 核心测试（宿主机，无需 NDK）
cd rust && cargo test --workspace

# Rust 侧格式 / 静态检查
cd rust && cargo fmt --all && cargo clippy --workspace --all-targets

# 改过 rust/ffi 的接口后，重新生成 Dart 绑定
cd app && flutter_rust_bridge_codegen generate

# 打 APK（先编各 ABI 的 .so，再 flutter build apk）
scripts/build-apk.sh              # debug
scripts/build-apk.sh --release    # release

# 只跑 Dart 侧
cd app && flutter analyze && flutter test
```

## 几个必须知道的坑

- **直接 `flutter build apk` 不会编译 Rust**。本项目用“手动 jniLibs”方案（没启用 flutter_rust_bridge 的
  cargokit 插件），所以请始终用 `scripts/build-apk.sh`；否则 APK 能装上、能启动，但一调 FFI 就崩。
  `app/android/app/src/main/jniLibs/` 是构建产物，已被 git 忽略，需要时就地重新生成。
- Flutter 默认打 `armeabi-v7a` / `arm64-v8a` / `x86_64` 三个 ABI，**三个都要有 `.so`**，脚本已覆盖。
- `flutter_rust_bridge` 版本在**三处必须一致**：`rust/ffi/Cargo.toml`、`app/pubspec.yaml`、codegen CLI。
- Gradle 发行包走腾讯镜像（见 `app/android/gradle/wrapper/gradle-wrapper.properties`）：
  `services.gradle.org` 在本机连接超时，`mirrors.cloud.tencent.com/gradle/` 正常。
- 首次 `flutter build apk` 会下载 Gradle 9.3.1 + AGP 9.1.0 + Kotlin 依赖（约数 GB、十余分钟），
  之后增量构建在秒级。
