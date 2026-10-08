import 'dart:math' as math;
import 'dart:typed_data';

/// Quietest level we report, so silence doesn't produce -infinity.
const double minDb = -100;

/// Converts dBFS to the app's sound scale, where 0 dB is a whisper.
///
/// Android requires the voice-recognition microphone to read a 1 kHz tone
/// at 90 dB SPL as RMS 2500 of 16-bit full scale (-22.4 dBFS), so
/// SPL = dBFS + 112.4. A whisper is about 30 dB SPL. Phones differ by a few
/// dB, so treat the result as an estimate.
const double dbfsToSoundDb = 112.4 - 30;

/// [dbfs] on the app's sound scale (0 dB is a whisper).
double soundDb(double dbfs) => dbfs + dbfsToSoundDb;

/// Below this the microphone is delivering digital silence (all zeros),
/// typically while it starts up. No real room is this quiet.
const double digitalSilenceDb = -90;

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
  NoiseFloor({
    this.fallRate = 0.1,
    this.riseRate = 1 / 1200,
    this.warmupFrames = 50,
  });

  /// Fraction of the gap closed per frame when the level is below the floor.
  final double fallRate;

  /// Fraction of the gap closed per frame when the level is above the floor.
  /// The default is a ~2 minute time constant at 100 ms frames.
  final double riseRate;

  /// For this many frames after the first real one, the floor follows the
  /// level both ways at [fallRate], so it settles on the room in seconds.
  final int warmupFrames;

  double? _floor;
  int _frames = 0;

  double get value => _floor ?? minDb;

  double update(double levelDb) {
    // Digital silence from a starting microphone isn't the room. Letting it
    // in pinned the floor near -100 dBFS, and with the slow rise every sound
    // then read ~50 dB over background for minutes.
    if (levelDb <= digitalSilenceDb) return value;
    final f = _floor;
    _frames++;
    if (f == null) return _floor = levelDb;
    final rate = levelDb < f || _frames <= warmupFrames ? fallRate : riseRate;
    return _floor = f + (levelDb - f) * rate;
  }
}
