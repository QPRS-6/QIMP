/// 全局产品信息常量。
///
/// 单独放一个文件，避免 `main.dart` 与页面之间互相 import 形成环。
library;

/// 应用名：同时用作 `MaterialApp.title`、AppBar 标题与桌面/任务栏名字。
///
/// Android 那边还有一份同名的（`res/values/strings.xml` 的 `app_name`）：
/// 启动器图标、通知栏、桌面小部件读的都是它——那份改不了由 Dart 常量生成，
/// 只能两处一起改，所以名字**只在这里和那里各写一遍**，别在别处再抄一份。
const String kAppTitle = 'QIMP';

