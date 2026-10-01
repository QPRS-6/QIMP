// 「这是不是平板 / 横没横过来 / 主页该不该锁竖屏」这几个判断单独放这里。
//
// 纯函数、不碰 FFI、不碰 Flutter 的渲染：宿主机上 `flutter test` 就能测，
// 也免得这些判断散在页面里，将来多点几处还要各写一遍。
import 'dart:ui' show Size;

import 'package:flutter/services.dart' show DeviceOrientation;

/// 判定「平板」的那条线：窗口**最短边**至少这么宽（逻辑像素）。
///
/// 600 不是我随手定的：Android 的资源限定符 `sw600dp` 就是按它分「手机 / 平板」，
/// 系统自己的多窗格界面也是从这一档开始给的。跟着它走，用户眼里的「平板」
/// 和我们这里的判断就是同一批设备。
const double kTabletMinShortestSide = 600;

/// 这个窗口尺寸要不要用平板那一套界面。
///
/// 看的是尺寸，不是型号：折叠屏展开、平板、桌面上的窗口都是同一件事。
/// 用的是**最短边**而不是宽度——竖着拿、横着拿是同一台设备，
/// 转个方向就换一套布局只会让人以为界面坏了。
bool useTabletLayout(Size size) => size.shortestSide >= kTabletMinShortestSide;

/// 窗口是不是横着拿的（宽比高长）。
///
/// 播放界面靠它挑版式：手机上横屏时竖向只剩三百来点，竖着排的标题 / 进度 / 两排按钮
/// 会挤成一团，得改成左右分栏（见 `player_page` 的 `_landscapeBody`）。
bool isLandscape(Size size) => size.width > size.height;

/// 曲库（主页）允许的屏幕方向：**手机锁竖屏**，平板随意。
///
/// 手机横过来看曲库，内容还是竖着排的：只是把整个列表压成中间一条、两边全是空白，
/// 那种「横屏」没有任何好处，所以主页干脆锁住。平板不锁——11 寸横着拿是常态，
/// 曲库也会跟着变宽。
///
/// **只管主页**：播放界面是另一回事（手机上横屏有专门的左右分栏），所以进播放界面
/// 之前会把这个限制放开、回来再锁上（见 `library_page` 的 `_openPlayer`）。
List<DeviceOrientation> homeOrientations(Size size) => useTabletLayout(size)
    ? DeviceOrientation.values
    : const [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown];

