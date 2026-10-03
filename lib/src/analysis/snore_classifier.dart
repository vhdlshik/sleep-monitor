import '../models.dart';

/// Marks bursts that repeat with a breathing rhythm as snores.
///
/// Snoring happens on (almost) every breath, so a snore is a burst that is
/// part of a chain of at least [minChain] bursts spaced [minGap]..[maxGap]
/// apart, where each gap is within [tolerance] of the previous one. Lone
/// bursts (a cough, a door) stay plain bursts.
void classifySnores(
  List<SoundEvent> events, {
  int minChain = 3,
  Duration minGap = const Duration(seconds: 2),
  Duration maxGap = const Duration(seconds: 10),
  double tolerance = 0.4,
}) {
  final sorted = [...events]..sort((a, b) => a.start.compareTo(b.start));
  for (final e in sorted) {
    e.type = SoundEventType.burst;
  }

  var chainStart = 0;
  Duration? lastGap;
  void close(int end) {
    if (end - chainStart >= minChain) {
      for (var k = chainStart; k < end; k++) {
        sorted[k].type = SoundEventType.snore;
      }
    }
  }

  for (var i = 1; i < sorted.length; i++) {
    final gap = sorted[i].start.difference(sorted[i - 1].start);
    final inRange = gap >= minGap && gap <= maxGap;
    final steady =
        lastGap == null ||
        (gap.inMilliseconds - lastGap.inMilliseconds).abs() <=
            lastGap.inMilliseconds * tolerance;
    if (inRange && steady) {
      lastGap = gap;
      continue;
    }
    close(i);
    chainStart = i;
    lastGap = null;
    // The current gap may still be the first link of a new chain.
    if (inRange) {
      chainStart = i - 1;
      lastGap = gap;
    }
  }
  close(sorted.length);
}
