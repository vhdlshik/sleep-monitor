import '../models.dart';

enum SleepStage { awake, rem, light, deep }

/// Estimates sleep stages from sound alone.
///
/// This is a heuristic, not a medical measurement. Sound tells us about
/// movement (rustling, bursts that aren't snores) and breathing, so:
/// * a restless epoch, smoothed over its neighbours, is [SleepStage.awake];
/// * the time before the first 5 quiet minutes is awake (falling asleep);
/// * long, very quiet stretches early in a ~90 minute cycle are
///   [SleepStage.deep], mostly in the first half of the night;
/// * quiet stretches without snoring late in a cycle are [SleepStage.rem]
///   (muscles relax in REM, so snoring usually drops);
/// * everything else is [SleepStage.light].
///
/// Adding motion or heart-rate sensors later should replace most of this.
class SleepStager {
  const SleepStager({
    this.cycle = const Duration(minutes: 90),
    this.wakeScore = 0.3,
    this.deepScore = 0.05,
    this.remScore = 0.15,
    this.onsetEpochs = 10,
  });

  final Duration cycle;
  final double wakeScore;
  final double deepScore;
  final double remScore;

  /// Consecutive calm epochs that mark falling asleep.
  final int onsetEpochs;

  static const _weights = [1.0, 1.0, 2.0, 4.0, 2.0, 1.0, 1.0];

  List<SleepStage> stage(List<Epoch> epochs, List<SoundEvent> events) {
    if (epochs.isEmpty) return const [];
    final n = epochs.length;
    final epochLength = n > 1
        ? epochs[1].start.difference(epochs[0].start)
        : const Duration(seconds: 30);

    final movement = List<int>.filled(n, 0);
    final snoring = List<bool>.filled(n, false);
    for (final e in events) {
      final i = _index(epochs, e.start, epochLength);
      if (i == null) continue;
      if (e.type == SoundEventType.snore) {
        snoring[i] = true;
      } else {
        movement[i]++;
      }
    }

    final raw = [
      for (var i = 0; i < n; i++)
        epochs[i].activeFraction * (snoring[i] ? 0.3 : 1.0) +
            (movement[i] > 3 ? 3 : movement[i]) * 0.15,
    ];
    final score = _smooth(raw);

    var onset = n;
    var calm = 0;
    for (var i = 0; i < n; i++) {
      calm = score[i] <= wakeScore ? calm + 1 : 0;
      if (calm >= onsetEpochs) {
        onset = i - onsetEpochs + 1;
        break;
      }
    }

    final sleepSpan = epochs.last.start.difference(
      epochs[onset < n ? onset : 0].start,
    );
    return [
      for (var i = 0; i < n; i++)
        _classify(
          i < onset,
          score[i],
          snoring[i],
          onset < n
              ? epochs[i].start.difference(epochs[onset].start)
              : Duration.zero,
          sleepSpan,
        ),
    ];
  }

  SleepStage _classify(
    bool beforeOnset,
    double score,
    bool snoring,
    Duration sinceOnset,
    Duration sleepSpan,
  ) {
    if (beforeOnset || score > wakeScore) return SleepStage.awake;
    final cycleIndex = sinceOnset.inSeconds ~/ cycle.inSeconds;
    final phase = (sinceOnset.inSeconds % cycle.inSeconds) / cycle.inSeconds;
    final earlyNight =
        sleepSpan.inSeconds == 0 ||
        sinceOnset.inSeconds / sleepSpan.inSeconds < 0.5;

    if (score <= deepScore) {
      final deepWindow = earlyNight
          ? phase >= 0.15 && phase <= 0.6
          : phase >= 0.25 && phase <= 0.45;
      if (deepWindow) return SleepStage.deep;
    }
    if (score <= remScore && !snoring) {
      final remStart = cycleIndex == 0 ? 0.85 : 0.7;
      if (phase >= remStart) return SleepStage.rem;
    }
    return SleepStage.light;
  }

  static List<double> _smooth(List<double> raw) {
    const centre = 3;
    return [
      for (var i = 0; i < raw.length; i++)
        () {
          var sum = 0.0, weight = 0.0;
          for (var k = 0; k < _weights.length; k++) {
            final j = i + k - centre;
            if (j < 0 || j >= raw.length) continue;
            sum += raw[j] * _weights[k];
            weight += _weights[k];
          }
          return sum / weight;
        }(),
    ];
  }

  static int? _index(List<Epoch> epochs, DateTime t, Duration epochLength) {
    final offset = t.difference(epochs.first.start);
    if (offset.isNegative) return null;
    final i = offset.inMilliseconds ~/ epochLength.inMilliseconds;
    return i < epochs.length ? i : null;
  }
}
