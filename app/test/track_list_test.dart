// 曲目列表（主页那一份）的用例。
//
// 多选模式不是“多画一个方框”那么简单：点一下的含义会从「播这首」变成「勾这首」，
// 长按也要让位——否则用户想勾几首，手一抖却弹出动作表。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/src/rust/api/library.dart';
import 'package:musicplayer/src/track_list.dart';

import 'fixtures.dart';

Widget harness({
  bool selecting = false,
  Set<int> selectedIds = const <int>{},
  List<Track>? tracks,
  VoidCallback? onPlay,
  VoidCallback? onToggleSelect,
  VoidCallback? onLongPress,
}) {
  final list =
      tracks ??
      <Track>[
        fakeTrack(id: 1, title: '第一首'),
        fakeTrack(id: 2, title: '第二首'),
      ];
  return MaterialApp(
    home: Scaffold(
      body: TrackList(
        tracks: list,
        emptyHint: '曲库是空的。',
        playingId: 1,
        onPlay: (index) => onPlay?.call(),
        onToggleSelect: (track) => onToggleSelect?.call(),
        onLongPress: (track) => onLongPress?.call(),
        selecting: selecting,
        selectedIds: selectedIds,
      ),
    ),
  );
}

void main() {
  testWidgets('平时：点一下是播放，长按交给上层', (tester) async {
    var played = 0;
    var longPressed = 0;
    await tester.pumpWidget(
      harness(
        onPlay: () => played += 1,
        onLongPress: () => longPressed += 1,
      ),
    );

    expect(find.byType(Checkbox), findsNothing, reason: '平时不该有复选框');
    await tester.tap(find.text('第二首'));
    await tester.pumpAndSettle();
    expect(played, 1);

    await tester.longPress(find.text('第一首'));
    await tester.pumpAndSettle();
    expect(longPressed, 1);
  });

  testWidgets('多选：左侧变复选框，点行是勾选而不是播放', (tester) async {
    var played = 0;
    var toggled = 0;
    var longPressed = 0;
    await tester.pumpWidget(
      harness(
        selecting: true,
        selectedIds: const <int>{1},
        onPlay: () => played += 1,
        onToggleSelect: () => toggled += 1,
        onLongPress: () => longPressed += 1,
      ),
    );

    expect(find.byType(Checkbox), findsNWidgets(2));
    expect(
      tester.widget<Checkbox>(find.byType(Checkbox).first).value,
      isTrue,
      reason: '已勾选的那首要显示为选中',
    );
    expect(tester.widget<Checkbox>(find.byType(Checkbox).last).value, isFalse);

    await tester.tap(find.text('第二首'));
    await tester.pumpAndSettle();
    expect(toggled, 1);
    expect(played, 0, reason: '多选时点行不该开始播放');

    // 长按也要让位，否则勾选过程中会误弹动作表。
    await tester.longPress(find.text('第二首'));
    await tester.pumpAndSettle();
    expect(longPressed, 0);
  });

  testWidgets('点复选框本身也算勾选（手最容易落在的地方）', (tester) async {
    var toggled = 0;
    await tester.pumpWidget(
      harness(selecting: true, onToggleSelect: () => toggled += 1),
    );

    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    expect(toggled, 1);
  });

  testWidgets('列表空了就显示上层给的那句话', (tester) async {
    await tester.pumpWidget(harness(tracks: const <Track>[]));
    expect(find.text('曲库是空的。'), findsOneWidget);
  });
}
