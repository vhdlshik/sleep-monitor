import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:sleep_monitor/src/models.dart';
import 'package:sleep_monitor/src/ui/sound_chart.dart';

void main() {
  final t0 = DateTime(2026, 10, 2, 23);
  final snore = t0.add(const Duration(hours: 3));
  final night = NightSession(
    id: 'n',
    start: t0,
    end: t0.add(const Duration(hours: 8)),
    levels: LevelTrack(
      start: t0,
      peaks: List.generate(8 * 3600, (i) => i % 600 == 0 ? -30.0 : -75.0),
    ),
    events: [
      SoundEvent(
        start: snore,
        duration: const Duration(milliseconds: 600),
        peakDb: -30,
        type: SoundEventType.snore,
      ),
    ],
    clips: [
      Clip(
        file: 'a.wav',
        start: snore.subtract(const Duration(seconds: 3)),
        end: snore.add(const Duration(seconds: 20)),
        kind: ClipKind.burst,
      ),
    ],
  );

  Future<List<DateTime>> pump(WidgetTester tester) async {
    final taps = <DateTime>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            child: SoundChart(night: night, onEventTap: taps.add),
          ),
        ),
      ),
    );
    return taps;
  }

  String range(WidgetTester tester) =>
      tester.widget<Text>(find.textContaining('–').first).data!;

  testWidgets('shows the whole night and zooms in and back out', (
    tester,
  ) async {
    await pump(tester);
    final hm = DateFormat.Hm();
    expect(
      range(tester),
      '${hm.format(t0)} – ${hm.format(t0.add(const Duration(hours: 8)))}',
    );

    await tester.tap(find.byTooltip('Zoom in'));
    await tester.pump();
    expect(
      range(tester),
      '${hm.format(t0.add(const Duration(hours: 2)))} – '
      '${hm.format(t0.add(const Duration(hours: 6)))}',
    );

    // Dragging right by half the width shows about two hours earlier.
    await tester.drag(find.byType(CustomPaint).last, const Offset(200, 0));
    await tester.pump();
    expect(range(tester), startsWith('23:'));

    await tester.tap(find.byTooltip('Whole night'));
    await tester.pump();
    expect(range(tester), startsWith(hm.format(t0)));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('tapping a snore line reports its time', (tester) async {
    final taps = await pump(tester);
    final paint = find.byType(CustomPaint).last;
    final box = tester.getRect(paint);
    // Plot starts 32 px in; the snore is 3 of 8 hours across.
    final x = box.left + 32 + (box.width - 32) * 3 / 8;
    await tester.tapAt(Offset(x, box.center.dy));
    await tester.pump(const Duration(milliseconds: 400));
    expect(taps, [snore]);
  });
}
