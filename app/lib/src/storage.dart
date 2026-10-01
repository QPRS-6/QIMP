import 'package:flutter/services.dart';

/// 存储权限桥，对应 `MainActivity` 里的 `com.qprs.musicplayer/storage` 通道。
///
/// 为什么不用插件：这里只需要“查一次 / 跳一次授权页”两个方法，
/// 手写 MethodChannel 比引入 `permission_handler` 依赖更少、更好跟进 AGP 升级。
class StorageAccess {
  const StorageAccess._();

  static const MethodChannel _channel = MethodChannel(
    'com.qprs.musicplayer/storage',
  );

  /// 是否已获得存储访问权（Android 11+ 是“所有文件访问”，更低版本是读存储）。
  static Future<bool> granted() async =>
      await _channel.invokeMethod<bool>('hasStorageAccess') ?? false;

  /// 跳到系统授权页。用户返回后需要重新调用 [granted] 复查（页面在 resume 时会做）。
  static Future<void> request() async {
    await _channel.invokeMethod<void>('requestStorageAccess');
  }
}
