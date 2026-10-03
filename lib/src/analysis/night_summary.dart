import '../models.dart';
import 'sleep_stager.dart';

/// A stretch of continuous snoring.
class SnoreEpisode {
  const SnoreEpisode(this.start, this.end, this.count);

  final DateTime start;
  final DateTime end;
  final int count;
}

/// What the morning screen shows for one night.
class NightSummary {
  NightSummary._(this.night, this.stages, this.episodes);

  factory NightSummary.of(
    NightSession night, {
    SleepStager stager = const SleepStager(),
  }) {
    final stages = stager.stage(night.epochs, night.events);
    return NightSummary._(night, stages, groupSnores(night.snores));
  }

  final NightSession night;

  /// One stage per epoch in [NightSession.epochs].
  final List<SleepStage> stages;
  final List<SnoreEpisode> episodes;

  Duration timeIn(SleepStage s) =>
      _epochLength * stages.where((x) => x == s).length;

  Duration get asleep =>
      timeIn(SleepStage.light) +
      timeIn(SleepStage.deep) +
      timeIn(SleepStage.rem);

  Duration get _epochLength => night.epochs.length > 1
      ? night.epochs[1].start.difference(night.epochs[0].start)
      : const Duration(seconds: 30);
}

/// Snores less than [gap] apart belong to one episode.
List<SnoreEpisode> groupSnores(
  List<SoundEvent> snores, {
  Duration gap = const Duration(minutes: 1),
}) {
  final sorted = [...snores]..sort((a, b) => a.start.compareTo(b.start));
  final out = <SnoreEpisode>[];
  DateTime? start, end;
  var count = 0;
  for (final s in sorted) {
    if (end != null && s.start.difference(end) <= gap) {
      end = s.start.add(s.duration);
      count++;
      continue;
    }
    if (start != null) out.add(SnoreEpisode(start, end!, count));
    start = s.start;
    end = s.start.add(s.duration);
    count = 1;
  }
  if (start != null) out.add(SnoreEpisode(start, end!, count));
  return out;
}
