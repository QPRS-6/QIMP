import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/src/library_page.dart';

/// 这些是纯函数，边界（0 / 负数 / 跨进位）最容易写错，所以单独测。
void main() {
  group('formatDuration（单曲时长 m:ss）', () {
    test('0 与负数按“未知”处理', () {
      expect(formatDuration(0), '--:--');
      expect(formatDuration(-1), '--:--');
    });

    test('常规换算并补零', () {
      expect(formatDuration(1000), '0:01');
      expect(formatDuration(59_400), '0:59');
      expect(formatDuration(60_000), '1:00');
      expect(formatDuration(208_000), '3:28');
    });
  });

  group('formatDurationLong（总时长 h:mm:ss）', () {
    test('不足一小时不显示小时位', () {
      expect(formatDurationLong(0), '0:00');
      expect(formatDurationLong(59_000), '0:59');
      expect(formatDurationLong(3_599_000), '59:59');
    });

    test('超过一小时用 h:mm:ss', () {
      expect(formatDurationLong(3_600_000), '1:00:00');
      // 真实曲库的 1688 分 04 秒，这正是之前显示成 1688:04 的那个值
      expect(formatDurationLong(101_284_000), '28:08:04');
    });
  });

  group('formatSize', () {
    test('按 1024 进位', () {
      expect(formatSize(512), '512 B');
      expect(formatSize(1024), '1.0 KB');
      expect(formatSize(1024 * 1024), '1.0 MB');
      expect(formatSize(10 * 1024 * 1024 * 1024), '10.0 GB');
    });
  });
}
