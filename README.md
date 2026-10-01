# ro.qprs.musicplayer

Android 端**纯本地**音乐播放器：Rust 负责全部逻辑（扫描 / 元数据 / 索引 / 歌词），Flutter 只负责界面。

## 目录结构

| 路径 | 说明 |
| --- | --- |
| `rust/core/` | 核心库，纯 Rust、不依赖 Android，可在宿主机直接 `cargo test` |
| `rust/audio/` | 播放层：symphonia 解码 + 播放队列 + 播放引擎；输出设备用 trait 抽象（Android 走 Oboe） |
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

# 抽查真实音乐文件的「精确跳转」落点精度（默认跳过，需指定文件）
cd rust && MUSIC_FILE=/tmp/song.mp3 cargo test -p musicplayer-audio \
  --test real_file_seek -- --ignored --nocapture

# 改过 rust/ffi 的接口后，重新生成 Dart 绑定
cd app && flutter_rust_bridge_codegen generate

# 打 APK（先编各 ABI 的 .so，再 flutter build apk）
scripts/build-apk.sh              # debug
scripts/build-apk.sh --release    # release

# 只跑 Dart 侧
cd app && flutter analyze && flutter test
```

## 权限说明（重要）

- **Android 11+ 必须授予“所有文件访问”**（`MANAGE_EXTERNAL_STORAGE`）。原因：核心扫描器基于
  `std::fs` + `walkdir`，需要真实文件路径；SAF 给的 `content://` URI 无法用它遍历。
  首次启动会引导你跳到系统设置页；调试时也可用 adb 直接授予：

  ```bash
  adb shell appops set --uid com.qprs.musicplayer MANAGE_EXTERNAL_STORAGE allow
  ```

- 扫描范围是下面这些目录中**实际存在**的那些（由 Rust 侧 `suggest_scan_roots()` 返回）：
  `/storage/emulated/0/{Music,Download,Podcasts,Recordings,Documents}`。
- 索引数据库落在应用私有目录：`files/library.db`（SQLite + WAL），不需要任何权限。

## 当前进度

- [x] Rust 核心库：目录扫描（增量 / 剪枝保护）、元数据与封面探测、SQLite 索引、歌词解析（44 项测试）
- [x] FFI 层：flutter_rust_bridge 2.13.0，Dart 直接使用 core 的类型（`#[frb(mirror)]`）
- [x] 曲库界面：授权引导 → 扫描 → 曲库统计 → 列表 / 搜索（真机验证：464 首 / 10.0 GB）
- [x] 播放（`rust/audio`）：symphonia 解码 + 无锁环形缓冲 + Oboe 输出、播放队列、播放 / 暂停 / 上下一首 / 跳转 / 循环模式、底部播放条与列表高亮
- [x] 后台播放与通知栏 / 锁屏 / 耳机按键控制（Kotlin 前台服务 + MediaSession，按钮经 JNI 直达 Rust）
- [x] 随机播放（一轮之内不重复）与定时播放（到点暂停）
- [x] 全屏播放界面：封面 / 标题 / 进度、上一曲·播放暂停·下一曲、随机 / 定时 / 循环；
      封面上右滑＝上一曲、左滑＝下一曲、上滑＝音量加、下滑＝音量减（改的是系统媒体音量）
- [x] 封面显示（列表与播放界面，内嵌图优先，其次同目录 `cover.jpg` / `folder.jpg`）
- [ ] 专辑 / 艺术家页、播放列表、继续播放

### 播放能放哪些格式

解码用 symphonia，**支持**：mp3 / flac / wav / aiff / m4a(mp4+aac+alac) / ogg(vorbis) / ogg(opus)。
其中 **Opus 不是 symphonia 自带的**（0.6 连特性都没有），靠 `symphonia-adapter-libopus` 把 libopus 接进来，
构建时会把 libopus 源码一起编进 `.so`，所以 Android 侧只需要 NDK 工具链、不依赖系统里的库。
这一点很值得记一笔：**手机录音与不少下载源的 `.ogg` 其实是 Opus**，只带 vorbis 时会直接“播不了”。

**不支持**：ape、wma、dsf/dff、mpc —— symphonia 没有这些解码器，扫得到但播不了，
播放失败时会在底部播放条上直接显示原因，不会静默失败。

**被截断的文件**（下载没下完）按“这首放完了”处理：能播的部分照播，之后自动接下一首，
不会因为一个坏文件把队列卡住。跳转落点实测：真 mp3 差 -31~-68ms、真 flac 差 -18~-86ms
（精确跳转只能落在帧 / 包边界上，且只会偏早），UI 上的 400ms 容差就是按这个定的。

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
- **C++ 运行时必须自己链**（`rust/ffi/build.rs`）：Oboe 是 C++ 库，而 cargo 在 Android 上用 NDK 的
  `clang`（C 驱动）做最终链接，不会像 `clang++` 那样自动带上 libc++。少了这一步，`.so` 里会留下
  `__cxa_pure_virtual` 这类未解析符号，**编得过、装得上，一启动就 `dlopen failed`**。
  排查手法（改完链接参数后建议都跑一遍，确认符号已静态解析）：
  ```bash
  unzip -p app/build/app/outputs/flutter-apk/app-debug.apk lib/arm64-v8a/libmusicplayer_ffi.so > /tmp/x.so
  llvm-readelf --dyn-syms /tmp/x.so | awk '$7=="UND" {print $8}' | grep -E 'cxa|_Z'
  # 只剩 __cxa_atexit/__cxa_finalize（由 Android 的 libc.so 提供）才是正常的
  ```
- **`symphonia` 需要 rustc ≥ 1.85**：`rust/audio/Cargo.toml` 单独抬高了这个 crate 的 `rust-version`，
  `core` / `ffi` 仍保持 workspace 的 1.82，别在 workspace 层面统一抬高。
- **Oboe 的立体声回调帧类型是 `(f32, f32)`**（帧切片，不是扁平采样），
  且回调里不能分配内存——所以交错缓冲要预先分配、越界部分补静音。
- 真机验证播放是否真的在出声（不用听）：
  ```bash
  adb shell dumpsys media.audio_flinger | grep -E 'qprs.*actual_seconds'
  # 隔 20 秒再跑一次，actual_seconds 的增量应约等于 20 秒
  ```
- **小米（HyperOS）会拒绝 adb 注入的点击**（`SecurityException: ... INJECT_EVENTS`），
  自动点击不可用，涉及播放控制的真机验证需要手动点。
