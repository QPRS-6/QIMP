//! JNI 薄层：Android 前台服务 / 通知栏通过它控制播放。
//!
//! 为什么不用 FRB：Flutter 引擎随 Activity 一起销毁，用户把 App 从任务列表划掉之后
//! Dart 侧就不在了，但播放和通知栏还得继续工作。所以这里直接暴露 JNI 接口，
//! Kotlin 侧 `PlaybackBridge` 用 `external fun` 调；它们与 FRB 访问同一份全局状态。
//!
//! 两条容易踩的规矩：
//! 1. 符号名 = `Java_<包名下划线化>_<类名>_<方法名>`。Kotlin 侧改包名、类名、方法名
//!    都必须同步改这里，否则是运行时 `UnsatisfiedLinkError`（编译期查不出来）。
//! 2. 绝不 panic 跨过 FFI 边界：取不到值就给 0 / null / false，并在 Kotlin 侧兜底。
//!    所以这里用的都是「返回 Option / Result」的桥接函数，逻辑在
//!    [`crate::api::playback_bridge`]（那份能在宿主机上测）。
//!
//! Kotlin 侧对应（`app/android/.../PlaybackBridge.kt`）：
//! ```kotlin
//! internal object PlaybackBridge {
//!     init { System.loadLibrary("musicplayer_ffi") }
//!     external fun stateCode(): Int
//!     // ...
//! }
//! ```

use jni::objects::{JByteArray, JObject, JString};
use jni::sys::{jboolean, jint, jlong, JNI_FALSE, JNI_TRUE};
use jni::JNIEnv;

use super::playback_bridge as bridge;

/// 第二个参数是 `JObject` 而不是 `JClass`：Kotlin 的 `object` 里的 `external fun`
/// 编译成**实例方法**（调用者是那个单例），JNI 传过来的是 jobject。

#[no_mangle]
pub extern "system" fn Java_com_qprs_musicplayer_PlaybackBridge_engineReady(
    _env: JNIEnv,
    _this: JObject,
) -> jboolean {
    if bridge::engine_ready() {
        JNI_TRUE
    } else {
        JNI_FALSE
    }
}

#[no_mangle]
pub extern "system" fn Java_com_qprs_musicplayer_PlaybackBridge_stateCode(
    _env: JNIEnv,
    _this: JObject,
) -> jint {
    bridge::state_code()
}

#[no_mangle]
pub extern "system" fn Java_com_qprs_musicplayer_PlaybackBridge_positionMs(
    _env: JNIEnv,
    _this: JObject,
) -> jlong {
    bridge::position_ms()
}

#[no_mangle]
pub extern "system" fn Java_com_qprs_musicplayer_PlaybackBridge_trackId(
    _env: JNIEnv,
    _this: JObject,
) -> jlong {
    bridge::track_id()
}

#[no_mangle]
pub extern "system" fn Java_com_qprs_musicplayer_PlaybackBridge_trackDurationMs(
    _env: JNIEnv,
    _this: JObject,
) -> jlong {
    bridge::track_duration_ms()
}

#[no_mangle]
pub extern "system" fn Java_com_qprs_musicplayer_PlaybackBridge_trackTitle<'local>(
    env: JNIEnv<'local>,
    _this: JObject<'local>,
) -> JString<'local> {
    // 造字符串失败（OOM 之类）就给 null：Kotlin 侧当空串，别把异常带回 JVM。
    env.new_string(bridge::track_title()).unwrap_or_default()
}

#[no_mangle]
pub extern "system" fn Java_com_qprs_musicplayer_PlaybackBridge_trackArtist<'local>(
    env: JNIEnv<'local>,
    _this: JObject<'local>,
) -> JString<'local> {
    env.new_string(bridge::track_artist()).unwrap_or_default()
}

#[no_mangle]
pub extern "system" fn Java_com_qprs_musicplayer_PlaybackBridge_errorText<'local>(
    env: JNIEnv<'local>,
    _this: JObject<'local>,
) -> JString<'local> {
    env.new_string(bridge::error_text()).unwrap_or_default()
}

/// 当前曲目的封面字节（没有封面时是空数组，构造失败时是 null）。
///
/// 图片给的是**字节**而不是 Bitmap：解码 / 缩放要用 `BitmapFactory`，
/// 那是 Kotlin 侧的事；Rust 只管把文件里的原图交出去，core 不碰任何图形 API。
#[no_mangle]
pub extern "system" fn Java_com_qprs_musicplayer_PlaybackBridge_coverBytes<'local>(
    env: JNIEnv<'local>,
    _this: JObject<'local>,
) -> JByteArray<'local> {
    // 造数组失败（OOM 之类）就给 null：Kotlin 侧当「这一首没有封面」，通知照样显示。
    env.byte_array_from_slice(&bridge::cover_bytes())
        .unwrap_or_default()
}

#[no_mangle]
pub extern "system" fn Java_com_qprs_musicplayer_PlaybackBridge_play(
    _env: JNIEnv,
    _this: JObject,
) -> jboolean {
    flag(bridge::play())
}

#[no_mangle]
pub extern "system" fn Java_com_qprs_musicplayer_PlaybackBridge_pause(
    _env: JNIEnv,
    _this: JObject,
) -> jboolean {
    flag(bridge::pause())
}

#[no_mangle]
pub extern "system" fn Java_com_qprs_musicplayer_PlaybackBridge_toggle(
    _env: JNIEnv,
    _this: JObject,
) -> jboolean {
    flag(bridge::toggle())
}

#[no_mangle]
pub extern "system" fn Java_com_qprs_musicplayer_PlaybackBridge_next(
    _env: JNIEnv,
    _this: JObject,
) -> jboolean {
    flag(bridge::next())
}

#[no_mangle]
pub extern "system" fn Java_com_qprs_musicplayer_PlaybackBridge_previous(
    _env: JNIEnv,
    _this: JObject,
) -> jboolean {
    flag(bridge::previous())
}

#[no_mangle]
pub extern "system" fn Java_com_qprs_musicplayer_PlaybackBridge_stop(
    _env: JNIEnv,
    _this: JObject,
) -> jboolean {
    flag(bridge::stop())
}

#[no_mangle]
pub extern "system" fn Java_com_qprs_musicplayer_PlaybackBridge_seekTo(
    _env: JNIEnv,
    _this: JObject,
    position_ms: jlong,
) -> jboolean {
    flag(bridge::seek_to(position_ms))
}

/// 随机播放开着没有（桌面小部件的图标状态）。
#[no_mangle]
pub extern "system" fn Java_com_qprs_musicplayer_PlaybackBridge_shuffleOn(
    _env: JNIEnv,
    _this: JObject,
) -> jboolean {
    flag(bridge::shuffle_on())
}

/// 当前循环模式的编码（与 `bridge::REPEAT_*` 一致）。
#[no_mangle]
pub extern "system" fn Java_com_qprs_musicplayer_PlaybackBridge_repeatCode(
    _env: JNIEnv,
    _this: JObject,
) -> jint {
    bridge::repeat_code()
}

/// 切换随机播放，返回切换后的状态。
#[no_mangle]
pub extern "system" fn Java_com_qprs_musicplayer_PlaybackBridge_toggleShuffle(
    _env: JNIEnv,
    _this: JObject,
) -> jboolean {
    flag(bridge::toggle_shuffle())
}

/// 循环模式转一圈，返回切换后的编码。
#[no_mangle]
pub extern "system" fn Java_com_qprs_musicplayer_PlaybackBridge_cycleRepeat(
    _env: JNIEnv,
    _this: JObject,
) -> jint {
    bridge::cycle_repeat()
}

/// Rust 的 `bool` 和 JNI 的 `jboolean` 都是 1 字节，但**规范上不要直接当同一个类型用**，
/// 这里显式转换，免得哪天布局变了踩坑。
fn flag(value: bool) -> jboolean {
    if value {
        JNI_TRUE
    } else {
        JNI_FALSE
    }
}
