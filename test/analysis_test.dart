import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_monitor/src/analysis/burst_detector.dart';
import 'package:sleep_monitor/src/analysis/level.dart';
import 'package:sleep_monitor/src/analysis/night_analyzer.dart';
import 'package:sleep_monitor/src/analysis/night_summary.dart';
import 'package:sleep_monitor/src/analysis/sleep_stager.dart';
import 'package:sleep_monitor/src/analysis/snore_classifier.dart';
import 'package:sleep_monitor/src/models.dart';

const frame = Duration(milliseconds: 100);
final t0 = DateTime(2026, 10, 3, 0, 0);

SoundEvent ev(int seconds) => SoundEvent(
  start: t0.add(Duration(seconds: seconds)),
  duration: const Duration(milliseconds: 800),
  peakDb: -30,
);

void main() {
  test('dBFS of a full-scale square wave is 0, silence is the minimum', () {
    expect(
      pcm16Dbfs(Int16List.fromList([32767, -32768, 32767, -32768])),
      closeTo(0, 0.01),
    );
    expect(pcm16Dbfs(Int16List(100)), minDb);
  });

  test('noise floor ignores a short loud sound', () {
    final f = NoiseFloor();
    for (var i = 0; i < 100; i++) {
      f.update(-60);
    }
    for (var i = 0; i < 10; i++) {
      f.update(-20);
    }
    expect(f.value, lessThan(-59));
  });

  test('burst detector reports a sudden short sound, not a slow rise', () {
    final d = BurstDetector(burstDb: 10);
    var t = t0;
    BurstUpdate step(double level) {
      t = t.add(frame);
      return d.update(t, level, -60);
    }

    for (var i = 0; i < 20; i++) {
      step(-60);
    }
    expect(step(-40).onset, isTrue);
    for (var i = 0; i < 5; i++) {
      step(-40);
    }
    final end = step(-60);
    expect(end.finished, isNotNull);
    expect(end.finished!.duration, const Duration(milliseconds: 600));

    // Rising 3 dB per second (a fan spinning up) is never "sudden".
    var onsets = 0;
    for (var i = 0; i < 100; i++) {
      if (step(-60.0 + i * 0.3).onset) onsets++;
    }
    expect(onsets, 0);
  });

  test('rhythmic bursts are snores, isolated ones are not', () {
    final events = [ev(0), ev(100), ev(104), ev(108), ev(112), ev(300)];
    classifySnores(events);
    expect(events.map((e) => e.type == SoundEventType.snore).toList(), [
      false,
      true,
      true,
      true,
      true,
      false,
    ]);
  });

  test('two bursts are not enough for snoring', () {
    final events = [ev(0), ev(4)];
    classifySnores(events);
    expect(events.every((e) => e.type == SoundEventType.burst), isTrue);
  });

  test('snores are grouped into episodes', () {
    final snores = [ev(0), ev(4), ev(8), ev(600), ev(604)];
    final eps = groupSnores(snores);
    expect(eps.length, 2);
    expect(eps.first.count, 3);
  });

  test('analyzer builds 30 s epochs and records a burst', () {
    final a = NightAnalyzer(const MonitorSettings());
    var starts = 0;
    for (var i = 0; i < 900; i++) {
      final level = i == 400 ? -30.0 : -60.0;
      if (a.process(t0.add(frame * i), level).action.name == 'start') starts++;
    }
    a.finish();
    expect(a.epochs.length, 3);
    expect(a.epochs[1].bursts, 1);
    expect(starts, 1);
  });

  group('sleep stager', () {
    List<Epoch> night(double Function(int i) activity, int n) => [
      for (var i = 0; i < n; i++)
        Epoch(
          start: t0.add(Duration(seconds: 30 * i)),
          meanDb: -60,
          maxDb: -50,
          floorDb: -60,
          activeFraction: activity(i),
          bursts: 0,
        ),
    ];

    test('restless start is awake, then sleep with deep and REM', () {
      // 15 restless minutes, then 6 quiet hours.
      final epochs = night((i) => i < 30 ? 0.8 : 0.0, 30 + 720);
      final stages = const SleepStager().stage(epochs, []);
      expect(stages.take(25).every((s) => s == SleepStage.awake), isTrue);
      expect(stages.contains(SleepStage.deep), isTrue);
      expect(stages.contains(SleepStage.rem), isTrue);
      expect(stages.contains(SleepStage.light), isTrue);
    });

    test('a restless spell in the night is awake', () {
      final epochs = night((i) => i >= 200 && i < 220 ? 0.9 : 0.0, 400);
      final stages = const SleepStager().stage(epochs, []);
      expect(stages[210], SleepStage.awake);
      expect(stages[100], isNot(SleepStage.awake));
    });
  });
}
