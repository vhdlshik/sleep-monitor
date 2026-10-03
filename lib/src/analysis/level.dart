import 'dart:math' as math;
import 'dart:typed_data';

/// Quietest level we report, so silence doesn't produce -infinity.
const double minDb = -100;

/// RMS level of little-endian 16-bit PCM samples, in dBFS.
double pcm16Dbfs(Int16List samples) {
  if (samples.isEmpty) return minDb;
  var sum = 0.0;
  for (final s in samples) {
    sum += s * s;
  }
  final rms = math.sqrt(sum / samples.length) / 32768.0;
  if (rms <= 0) return minDb;
  return math.max(minDb, 20 * math.log(rms) / math.ln10);
}

/// Tracks the room's background level.
///
/// Falls quickly towards quieter levels and rises slowly, so short sounds
/// (snores, coughs) barely move it while a fan switching on is picked up
/// within a few minutes.
class NoiseFloor {
  NoiseFloor({this.fallRate = 0.1, this.riseRate = 1 / 1200});

  /// Fraction of the gap closed per frame when the level is below the floor.
  final double fallRate;

  /// Fraction of the gap closed per frame when the level is above the floor.
  /// The default is a ~2 minute time constant at 100 ms frames.
  final double riseRate;

  double? _floor;

  double get value => _floor ?? minDb;

  double update(double levelDb) {
    final f = _floor;
    if (f == null) return _floor = levelDb;
    final rate = levelDb < f ? fallRate : riseRate;
    return _floor = f + (levelDb - f) * rate;
  }
}
