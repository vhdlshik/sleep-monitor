import 'dart:math' as math;

import '../models.dart';
import '../recording/recording_policy.dart';
import 'burst_detector.dart';
import 'level.dart';

/// Result of feeding one audio frame.
class FrameResult {
  const FrameResult({required this.action, required this.floorDb, this.event});

  final PolicyAction action;
  final double floorDb;
  final SoundEvent? event;
}

/// The whole per-frame pipeline without any I/O: background tracking, burst
/// detection, the recording policy and 30-second epoch statistics.
class NightAnalyzer {
  NightAnalyzer(this.settings, {this.epochLength = const Duration(seconds: 30)})
    : _detector = BurstDetector(burstDb: settings.burstDb),
      policy = RecordingPolicy(settings);

  /// Sound this far above background counts as activity (movement,
  /// rustling) for sleep staging. Separate from the recording threshold,
  /// which is an absolute level and would miss quiet movement.
  static const activityDb = 3.0;

  final MonitorSettings settings;
  final Duration epochLength;
  final NoiseFloor _floor = NoiseFloor();
  final BurstDetector _detector;
  final RecordingPolicy policy;

  final List<Epoch> epochs = [];
  final List<SoundEvent> events = [];

  /// Peak level per second, for the zoomable sound chart.
  LevelTrack? levels;

  DateTime? _epochStart;
  double _sumPower = 0;
  double _max = minDb;
  double _floorSum = 0;
  int _frames = 0;
  int _activeFrames = 0;
  int _bursts = 0;

  FrameResult process(DateTime t, double levelDb) {
    // Compare against the floor *before* this frame nudges it.
    final floor = _floor.value == minDb ? levelDb : _floor.value;
    final loud = soundDb(levelDb) >= settings.thresholdDb;
    final burst = _detector.update(t, levelDb, floor);
    final action = policy.update(t, loud: loud, burstOnset: burst.onset);
    _floor.update(levelDb);

    final event = burst.finished;
    if (event != null) events.add(event);
    final active = levelDb >= floor + activityDb;
    _accumulate(t, levelDb, floor, active, burst.onset);
    _track(t, levelDb);

    return FrameResult(action: action, floorDb: floor, event: event);
  }

  /// Closes the last, partial epoch.
  void finish() => _closeEpoch();

  void _track(DateTime t, double levelDb) {
    final track = levels ??= LevelTrack(start: t);
    final i =
        t.difference(track.start).inMilliseconds ~/ track.step.inMilliseconds;
    while (track.peaks.length <= i) {
      track.peaks.add(minDb);
    }
    if (levelDb > track.peaks[i]) track.peaks[i] = levelDb;
  }

  void _accumulate(
    DateTime t,
    double levelDb,
    double floor,
    bool active,
    bool onset,
  ) {
    final start = _epochStart;
    if (start == null) {
      _epochStart = t;
    } else if (t.difference(start) >= epochLength) {
      _closeEpoch();
      _epochStart = t;
    }
    _sumPower += _power(levelDb);
    if (levelDb > _max) _max = levelDb;
    _floorSum += floor;
    _frames++;
    if (active) _activeFrames++;
    if (onset) _bursts++;
  }

  void _closeEpoch() {
    final start = _epochStart;
    if (start == null || _frames == 0) return;
    epochs.add(
      Epoch(
        start: start,
        meanDb: _db(_sumPower / _frames),
        maxDb: _max,
        floorDb: _floorSum / _frames,
        activeFraction: _activeFrames / _frames,
        bursts: _bursts,
      ),
    );
    _epochStart = null;
    _sumPower = 0;
    _max = minDb;
    _floorSum = 0;
    _frames = 0;
    _activeFrames = 0;
    _bursts = 0;
  }
}

double _power(double db) => math.pow(10, db / 10).toDouble();
double _db(double power) =>
    power <= 0 ? minDb : 10 * math.log(power) / math.ln10;
