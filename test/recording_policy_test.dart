import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_monitor/src/models.dart';
import 'package:sleep_monitor/src/recording/recording_policy.dart';

const frame = Duration(milliseconds: 100);

/// Runs [policy] for [d] starting at [t], returning the frames recorded.
Duration run(
  RecordingPolicy policy,
  DateTime t,
  Duration d, {
  bool loud = false,
  bool burstAtStart = false,
}) {
  var recorded = Duration.zero;
  for (var i = 0; i < d.inMilliseconds ~/ frame.inMilliseconds; i++) {
    final now = t.add(frame * i);
    final a = policy.update(
      now,
      loud: loud,
      burstOnset: burstAtStart && i == 0,
    );
    if (policy.isRecording || a == PolicyAction.stop) recorded += frame;
  }
  return recorded;
}

void main() {
  final t0 = DateTime(2026, 10, 3, 1, 0);

  test('continuous noise is capped at 5 minutes per clock hour', () {
    final p = RecordingPolicy(const MonitorSettings());
    final recorded = run(p, t0, const Duration(minutes: 30), loud: true);
    expect(recorded.inSeconds, closeTo(300, 1));
    expect(p.isRecording, isFalse);
  });

  test('budget resets at the next hour', () {
    final p = RecordingPolicy(const MonitorSettings());
    run(p, t0, const Duration(minutes: 59, seconds: 59), loud: true);
    expect(p.isRecording, isFalse);
    run(
      p,
      DateTime(2026, 10, 3, 2, 0),
      const Duration(seconds: 10),
      loud: true,
    );
    expect(p.isRecording, isTrue);
  });

  test('bursts are recorded after the budget is spent and do not count', () {
    final p = RecordingPolicy(const MonitorSettings());
    run(p, t0, const Duration(minutes: 10), loud: true);
    final used = p.regularUsedIn(t0);
    final burstStart = t0.add(const Duration(minutes: 20));
    expect(
      p.update(burstStart, loud: true, burstOnset: true),
      PolicyAction.start,
    );
    expect(p.kind, ClipKind.burst);
    run(p, burstStart.add(frame), const Duration(seconds: 19));
    expect(p.isRecording, isTrue, reason: 'still inside the 20 s burst clip');
    expect(p.regularUsedIn(t0), used);
    run(
      p,
      burstStart.add(const Duration(seconds: 20)),
      const Duration(seconds: 1),
    );
    expect(p.isRecording, isFalse);
  });

  test('a quiet room stops a threshold recording after the hangover', () {
    final p = RecordingPolicy(const MonitorSettings());
    run(p, t0, const Duration(seconds: 2), loud: true);
    expect(p.isRecording, isTrue);
    run(p, t0.add(const Duration(seconds: 2)), const Duration(seconds: 6));
    expect(p.isRecording, isFalse);
  });

  test('burst audio has its own safety cap', () {
    final p = RecordingPolicy(
      const MonitorSettings(burstCapPerHour: Duration(seconds: 30)),
    );
    var t = t0;
    for (var i = 0; i < 5; i++) {
      run(p, t, const Duration(seconds: 25), burstAtStart: true);
      t = t.add(const Duration(seconds: 25));
    }
    expect(p.burstUsedIn(t0).inSeconds, lessThanOrEqualTo(31));
  });
}
