/// Data model for one monitored night and the user-tunable settings.
library;

/// User-adjustable monitoring settings.
///
/// [thresholdDb] is an absolute sound level on the app's scale, where 0 dB is
/// a whisper (see `soundDb`). [burstDb] is relative to the room's measured
/// background, since a burst is a sudden jump.
class MonitorSettings {
  const MonitorSettings({
    this.thresholdDb = 20.0,
    this.burstDb = 10.0,
    this.budgetPerHour = const Duration(minutes: 5),
    this.burstCapPerHour = const Duration(minutes: 15),
    this.burstClip = const Duration(seconds: 20),
    this.preRoll = const Duration(seconds: 3),
    this.hangover = const Duration(seconds: 5),
    this.retention = const Duration(days: 7),
  });

  /// Sound at or above this level (0 dB is a whisper) starts a regular
  /// recording.
  final double thresholdDb;

  /// A sudden jump this many dB above background counts as a burst
  /// (e.g. a snore). Bursts are always recorded.
  final double burstDb;

  /// Maximum regular (threshold) recording per clock hour.
  final Duration budgetPerHour;

  /// Safety cap for burst audio per clock hour, so a whole night of loud
  /// snoring can't fill the phone. Bursts beyond it are still timestamped.
  final Duration burstCapPerHour;

  /// How much audio each burst keeps after its onset.
  final Duration burstClip;

  /// Audio kept from before the trigger, so the start of a snore isn't cut.
  final Duration preRoll;

  /// A regular recording stops after this much quiet.
  final Duration hangover;

  /// Nights older than this are deleted.
  final Duration retention;

  MonitorSettings copyWith({double? thresholdDb, double? burstDb}) =>
      MonitorSettings(
        thresholdDb: thresholdDb ?? this.thresholdDb,
        burstDb: burstDb ?? this.burstDb,
        budgetPerHour: budgetPerHour,
        burstCapPerHour: burstCapPerHour,
        burstClip: burstClip,
        preRoll: preRoll,
        hangover: hangover,
        retention: retention,
      );
}

/// Aggregated sound statistics for one 30-second epoch.
class Epoch {
  const Epoch({
    required this.start,
    required this.meanDb,
    required this.maxDb,
    required this.floorDb,
    required this.activeFraction,
    required this.bursts,
  });

  final DateTime start;

  /// Mean level in dBFS.
  final double meanDb;
  final double maxDb;

  /// Background level at the time.
  final double floorDb;

  /// Share of the epoch with activity above background (0..1), see
  /// `NightAnalyzer.activityDb`.
  final double activeFraction;

  /// Bursts that started in this epoch.
  final int bursts;

  Map<String, Object?> toJson() => {
    't': start.millisecondsSinceEpoch,
    'mean': _r(meanDb),
    'max': _r(maxDb),
    'floor': _r(floorDb),
    'act': _r(activeFraction),
    'b': bursts,
  };

  factory Epoch.fromJson(Map<String, Object?> j) => Epoch(
    start: DateTime.fromMillisecondsSinceEpoch(j['t'] as int),
    meanDb: (j['mean'] as num).toDouble(),
    maxDb: (j['max'] as num).toDouble(),
    floorDb: (j['floor'] as num).toDouble(),
    activeFraction: (j['act'] as num).toDouble(),
    bursts: j['b'] as int,
  );
}

enum SoundEventType { burst, snore }

/// A detected sudden sound.
class SoundEvent {
  SoundEvent({
    required this.start,
    required this.duration,
    required this.peakDb,
    this.type = SoundEventType.burst,
  });

  final DateTime start;
  final Duration duration;
  final double peakDb;
  SoundEventType type;

  Map<String, Object?> toJson() => {
    't': start.millisecondsSinceEpoch,
    'd': duration.inMilliseconds,
    'peak': _r(peakDb),
    'type': type.name,
  };

  factory SoundEvent.fromJson(Map<String, Object?> j) => SoundEvent(
    start: DateTime.fromMillisecondsSinceEpoch(j['t'] as int),
    duration: Duration(milliseconds: j['d'] as int),
    peakDb: (j['peak'] as num).toDouble(),
    type: SoundEventType.values.byName(j['type'] as String),
  );
}

/// The sound level through the night at a fixed [step]: the loudest
/// 100 ms frame of each step, in dBFS. Detailed enough to zoom in on a
/// single snore, small enough to keep for every night.
class LevelTrack {
  LevelTrack({
    required this.start,
    this.step = const Duration(seconds: 1),
    List<double>? peaks,
  }) : peaks = peaks ?? [];

  final DateTime start;
  final Duration step;
  final List<double> peaks;

  DateTime timeOf(int i) => start.add(step * i);

  DateTime get end => timeOf(peaks.length);

  Map<String, Object?> toJson() => {
    't': start.millisecondsSinceEpoch,
    'step': step.inMilliseconds,
    // Tenths of a dB as integers keep a night's track around 150 KB.
    'v': [for (final p in peaks) (p * 10).round()],
  };

  factory LevelTrack.fromJson(Map<String, Object?> j) => LevelTrack(
    start: DateTime.fromMillisecondsSinceEpoch(j['t'] as int),
    step: Duration(milliseconds: j['step'] as int),
    peaks: [for (final v in j['v'] as List) (v as num) / 10],
  );
}

/// Why a clip was recorded. A clip that started on the threshold but was
/// extended by a burst stays [threshold].
enum ClipKind { threshold, burst }

/// A recorded audio file.
class Clip {
  const Clip({
    required this.file,
    required this.start,
    required this.end,
    required this.kind,
  });

  /// File name relative to the night's directory.
  final String file;
  final DateTime start;
  final DateTime end;
  final ClipKind kind;

  Duration get duration => end.difference(start);

  Map<String, Object?> toJson() => {
    'file': file,
    'start': start.millisecondsSinceEpoch,
    'end': end.millisecondsSinceEpoch,
    'kind': kind.name,
  };

  factory Clip.fromJson(Map<String, Object?> j) => Clip(
    file: j['file'] as String,
    start: DateTime.fromMillisecondsSinceEpoch(j['start'] as int),
    end: DateTime.fromMillisecondsSinceEpoch(j['end'] as int),
    kind: ClipKind.values.byName(j['kind'] as String),
  );
}

/// Everything recorded about one night.
class NightSession {
  NightSession({
    required this.id,
    required this.start,
    this.end,
    List<Epoch>? epochs,
    List<SoundEvent>? events,
    List<Clip>? clips,
    this.levels,
  }) : epochs = epochs ?? [],
       events = events ?? [],
       clips = clips ?? [];

  final String id;
  final DateTime start;
  DateTime? end;
  final List<Epoch> epochs;
  final List<SoundEvent> events;
  final List<Clip> clips;

  /// Per-second levels. Null for nights recorded before it was added.
  LevelTrack? levels;

  List<SoundEvent> get snores =>
      events.where((e) => e.type == SoundEventType.snore).toList();

  /// The recording that contains [t], if any.
  Clip? clipAt(DateTime t) {
    for (final c in clips) {
      if (!t.isBefore(c.start) && t.isBefore(c.end)) return c;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'id': id,
    'start': start.millisecondsSinceEpoch,
    'end': end?.millisecondsSinceEpoch,
    'epochs': [for (final e in epochs) e.toJson()],
    'events': [for (final e in events) e.toJson()],
    'clips': [for (final c in clips) c.toJson()],
    if (levels != null) 'levels': levels!.toJson(),
  };

  factory NightSession.fromJson(Map<String, Object?> j) => NightSession(
    id: j['id'] as String,
    start: DateTime.fromMillisecondsSinceEpoch(j['start'] as int),
    end: j['end'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(j['end'] as int),
    epochs: [
      for (final e in j['epochs'] as List) Epoch.fromJson((e as Map).cast()),
    ],
    events: [
      for (final e in j['events'] as List)
        SoundEvent.fromJson((e as Map).cast()),
    ],
    clips: [
      for (final c in j['clips'] as List) Clip.fromJson((c as Map).cast()),
    ],
    levels: j['levels'] == null
        ? null
        : LevelTrack.fromJson((j['levels'] as Map).cast()),
  );
}

double _r(double v) => (v * 10).roundToDouble() / 10;
