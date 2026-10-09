import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_monitor/src/analysis/burst_detector.dart';
import 'package:sleep_monitor/src/analysis/level.dart';
import 'package:sleep_monitor/src/analysis/night_analyzer.dart';
import 'package:sleep_monitor/src/analysis/night_summary.dart';
import 'package:sleep_monitor/src/analysis/sleep_stager.dart';
import 'package:sleep_monitor/src/analysis/snore_classifier.dart';
import 'package:sleep_monitor/src/models.dart';
import 'package:sleep_monitor/src/recording/recording_policy.dart';

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

  test('noise floor skips startup zeros and settles on the room fast', () {
    final f = NoiseFloor();
    for (var i = 0; i < 5; i++) {
      f.update(minDb);
    }
    // A low outlier first, then the real room.
    f.update(-75);
    for (var i = 0; i < 50; i++) {
      f.update(-60);
    }
    expect(f.value, closeTo(-60, 0.5));
  });

  test('sound scale puts a whisper (30 dB SPL) at 0 dB', () {
    // 90 dB SPL reads RMS 2500 on Android's voice-recognition mic.
    final dbfs90 = 20 * math.log(2500 / 32768) / math.ln10;
    expect(soundDb(dbfs90 - 60), closeTo(0, 0.1));
  });

  test('threshold is an absolute level, not above background', () {
    final a = NightAnalyzer(const MonitorSettings(thresholdDb: 20));
    var t = t0;
    PolicyAction step(double sound) {
      t = t.add(frame);
      return a.process(t, sound - dbfsToSoundDb).action;
    }

    // Startup zeros, then a quiet room at 5 dB: nothing is recorded.
    for (var i = 0; i < 5; i++) {
      step(minDb + dbfsToSoundDb);
    }
    for (var i = 0; i < 600; i++) {
      expect(step(5), PolicyAction.none);
    }
    // Steady 25 dB sound starts a recording.
    expect(step(25), PolicyAction.start);
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
      // A quiet room (about 12 dB) with one loud burst.
      final level = i == 400 ? -30.0 : -70.0;
      if (a.process(t0.add(frame * i), level).action.name == 'start') starts++;
    }
    a.finish();
    expect(a.epochs.length, 3);
    expect(a.epochs[1].bursts, 1);
    expect(starts, 1);
    expect(a.levels!.peaks.length, 90);
    expect(a.levels!.peaks[40], -30);
    expect(a.levels!.peaks[41], -70);
  });

  test('every snore falls inside a recording', () {
    final a = NightAnalyzer(const MonitorSettings());
    final spans = <(DateTime, DateTime)>[];
    DateTime? open;
    final end = t0.add(const Duration(minutes: 10));
    for (var t = t0; t.isBefore(end); t = t.add(frame)) {
      final s = t.difference(t0).inMilliseconds;
      // Quiet room, then a snore every 4 s (0.5 s long) for two minutes.
      final snoring = s >= 120000 && s < 240000 && s % 4000 < 500;
      final r = a.process(t, snoring ? -35.0 : -75.0);
      if (r.action == PolicyAction.start) open = t;
      if (r.action == PolicyAction.stop) {
        spans.add((open!, t.add(frame)));
        open = null;
      }
    }
    classifySnores(a.events);
    final snores = a.events.where((e) => e.type == SoundEventType.snore);
    expect(snores.length, greaterThan(20));
    for (final e in snores) {
      expect(
        spans.any((c) => !e.start.isBefore(c.$1) && e.start.isBefore(c.$2)),
        isTrue,
        reason: 'snore at ${e.start} not recorded',
      );
    }
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
