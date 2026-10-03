import '../models.dart';

/// What the detector saw in one frame.
class BurstUpdate {
  const BurstUpdate({this.onset = false, this.finished});

  /// A burst started in this frame. Recording should begin right away.
  final bool onset;

  /// A burst ended in this frame and was short enough to count as an event.
  final SoundEvent? finished;
}

/// Detects sudden, short sounds such as snores, coughs or gasps.
///
/// A burst starts when the level is [burstDb] above background *and* jumped
/// at least half that over the last second, so a slowly rising noise
/// (rain, a fan) doesn't count. It ends when the level falls back below
/// half of [burstDb] above background. Bursts longer than [maxDuration] are
/// sustained noise and aren't reported as events.
class BurstDetector {
  BurstDetector({
    required this.burstDb,
    this.frame = const Duration(milliseconds: 100),
    this.maxDuration = const Duration(seconds: 4),
  }) : _historyLength = (1000 / frame.inMilliseconds).round();

  final double burstDb;
  final Duration frame;
  final Duration maxDuration;
  final int _historyLength;
  final List<double> _history = [];

  DateTime? _start;
  double _peak = -double.infinity;

  bool get inBurst => _start != null;

  BurstUpdate update(DateTime t, double levelDb, double floorDb) {
    final recent = _history.isEmpty
        ? levelDb
        : _history.reduce((a, b) => a + b) / _history.length;
    _history.add(levelDb);
    if (_history.length > _historyLength) _history.removeAt(0);

    final start = _start;
    if (start == null) {
      final loud = levelDb >= floorDb + burstDb;
      final sudden = levelDb - recent >= burstDb / 2;
      if (loud && sudden) {
        _start = t;
        _peak = levelDb;
        return const BurstUpdate(onset: true);
      }
      return const BurstUpdate();
    }

    if (levelDb > _peak) _peak = levelDb;
    if (levelDb >= floorDb + burstDb / 2) return const BurstUpdate();

    _start = null;
    final duration = t.difference(start);
    if (duration > maxDuration) return const BurstUpdate();
    return BurstUpdate(
      finished: SoundEvent(start: start, duration: duration, peakDb: _peak),
    );
  }
}
