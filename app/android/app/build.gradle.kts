import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// release 签名。keystore 与口令写在 `android/key.properties` 里，那份文件不进版本库
// （见 `android/.gitignore`），keystore 本体放在仓库外面（`~/.android-keystores/`）——
// `git clean -xfd` 会把忽略文件一起删掉，放仓库里早晚被误删。
//
// 没有这份 properties 时**退回 debug 签名**：别人 clone 下来照样能 `flutter build apk`，
// 只是产出的包不能覆盖安装你签名的那个（签名不同，Android 直接拒绝）。
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

android {
    namespace = "com.qprs.musicplayer"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.qprs.musicplayer"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                // 路径写错 / keystore 被挪走时，让构建在这里就报清楚，而不是等到
                // apksigner 抛一句看不懂的话。
                if (storeFile?.exists() != true) {
                    throw GradleException(
                        "key.properties 里的 storeFile 不存在：${storeFile?.absolutePath}"
                    )
                }
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                // 兜底：debug 签名只够本机跑 `flutter run --release`，不能用于分发。
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // 前台服务 + 通知栏控制用的媒体会话（MediaSessionCompat / MediaStyle / MediaButtonReceiver）。
    // Flutter 自带的依赖里没有它，但它不大，而且是这套通知栏方案的官方库。
    implementation("androidx.media:media:1.7.0")

    // 宿主机单元测试：`cd app/android && ./gradlew :app:testDebugUnitTest`。
    // 只测不碰 Android 运行时的纯逻辑（自动暂停那两条规则），所以用不上 Robolectric。
    testImplementation("junit:junit:4.13.2")
}

flutter {
    source = "../.."
}
