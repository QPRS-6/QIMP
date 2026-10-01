// 定时播放的用例：到点触发一次、能取消、重新设定会覆盖。
//
// 倒计时基于 Timer.periodic（由 FakeAsync 驱动，不用真的等），
// 「现在几点」则是注入进来的假时钟——`testWidgets` 的 FakeAsync
// 不会替换 `DateTime.now()`，不注入的话截止时刻永远停在真实时间上。
import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/src/sleep_timer.dart';

void main() {
  /// 假时钟：测试里手动推进它，与 `tester.pump` 同步。
  late DateTime now;

  setUp(() => now = DateTime(2026, 1, 1, 22, 0));

  SleepTimer timerThatCounts(List<int> fired) => SleepTimer(
    onFire: () => fired.add(1),
    now: () => now,
  );

  /// 推进时间：假时钟与 FakeAsync 一起走，模拟「真实地过了一秒」。
  Future<void> advance(WidgetTester tester, Duration step) async {
    now = now.add(step);
    await tester.pump(step);
  }

  testWidgets('到点触发一次，并把状态清干净', (tester) async {
    final fired = <int>[];
    final timer = timerThatCounts(fired);
    addTearDown(timer.dispose);

    timer.set(const Duration(seconds: 3));
    expect(timer.isActive, isTrue);
    expect(timer.remaining, const Duration(seconds: 3));

    await advance(tester, const Duration(seconds: 1));
    expect(timer.remaining, const Duration(seconds: 2), reason: '剩余时间应该在走');

    await advance(tester, const Duration(seconds: 2));
    expect(fired, [1], reason: '到点应该触发一次');
    expect(timer.isActive, isFalse, reason: '触发之后不该还显示在定时中');
  });

  testWidgets('取消之后不再触发', (tester) async {
    final fired = <int>[];
    final timer = timerThatCounts(fired);
    addTearDown(timer.dispose);

    timer.set(const Duration(seconds: 5));
    timer.cancel();
    expect(timer.isActive, isFalse);
    expect(timer.remaining, isNull);

    await advance(tester, const Duration(seconds: 10));
    expect(fired, isEmpty, reason: '已经取消就不该再触发');
  });

  testWidgets('重新设定会覆盖上一个时长', (tester) async {
    final fired = <int>[];
    final timer = timerThatCounts(fired);
    addTearDown(timer.dispose);

    timer.set(const Duration(minutes: 30));
    timer.set(const Duration(seconds: 2));

    await advance(tester, const Duration(seconds: 1));
    expect(fired, isEmpty, reason: '旧的 30 分钟不该还在跑');

    await advance(tester, const Duration(seconds: 1));
    expect(fired, [1]);
  });
}
