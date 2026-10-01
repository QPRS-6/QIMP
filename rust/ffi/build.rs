//! 链接脚本：Android 上必须显式把 C++ 运行时静态链进来。
//!
//! 为什么需要它：`oboe`（音频输出）是 C++ 库，而 cargo 在 Android 上用的是 NDK 的
//! **C 驱动 `clang`** 做最终链接，不像 `clang++` 那样自动带上 libc++。结果是
//! `.so` 里留下 `__cxa_pure_virtual` 这类未解析符号，表现为应用一启动就
//! `dlopen failed: cannot locate symbol "__cxa_pure_virtual"`——**编译期完全看不出来**。
//!
//! 选择静态链接而不是 `-lc++_shared`：省掉往 APK 里塞 `libc++_shared.so` 的步骤，
//! 也避免将来引入别的 C++ 插件时出现两份 libc++ 打架。代价只是 `.so` 略大一点。
//!
//! 注意用 `rustc-link-arg`（追加在链接命令**末尾**）而不是 `rustc-link-lib`：
//! 静态库必须排在引用它的目标之后，靠 cargo 的库顺序碰运气不如直接把参数放末尾。
fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("android") {
        println!("cargo:rustc-link-arg=-lc++_static");
        // `__cxa_pure_virtual` 等 C++ ABI 符号在 libc++abi 里，少了它照样链接不过运行时。
        println!("cargo:rustc-link-arg=-lc++abi");
        println!("cargo:rerun-if-changed=build.rs");
    }
}
