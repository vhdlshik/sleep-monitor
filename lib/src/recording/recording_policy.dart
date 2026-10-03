import '../models.dart';

enum PolicyAction { none, start, stop }

/// Decides when to record, frame by frame.
///
/// Rules:
/// * Sound [MonitorSettings.thresholdDb] above background starts a regular
///   recording, which stops after [MonitorSettings.hangover] of quiet.
/// * Regular recording is limited to [MonitorSettings.budgetPerHour] per
///   clock hour.
/// * A burst always opens (or extends) a protected window of
///   [MonitorSettings.burstClip]. Time inside it doesn't count towards the
///   hourly budget, and the recording can't stop during it.
/// * Burst time has its own, larger safety cap
///   ([MonitorSettings.burstCapPerHour]) so the phone can't fill up.
class RecordingPolicy {
  RecordingPolicy(this.settings);

  final MonitorSettings settings;

  final Map<DateTime, Duration> _regularUsed = {};
  final Map<DateTime, Duration> _burstUsed = {};

  bool _recording = false;
  ClipKind? _kind;
  DateTime? _protectedUntil;
  DateTime? _lastLoud;
  DateTime? _lastFrame;

  bool get isRecording => _recording;

  /// Why the current recording was started.
  ClipKind? get kind => _kind;

  Duration regularUsedIn(DateTime t) => _regularUsed[_hour(t)] ?? Duration.zero;
  Duration burstUsedIn(DateTime t) => _burstUsed[_hour(t)] ?? Duration.zero;

  bool _budgetLeft(DateTime t) => regularUsedIn(t) < settings.budgetPerHour;
  bool _burstCapLeft(DateTime t) => burstUsedIn(t) < settings.burstCapPerHour;

  /// Feeds one frame starting at [t]. [loud] means the level is above the
  /// recording threshold; [burstOnset] means a burst started in this frame.
  PolicyAction update(
    DateTime t, {
    required bool loud,
    required bool burstOnset,
  }) {
    final last = _lastFrame;
    final frame = last == null ? Duration.zero : t.difference(last);
    _lastFrame = t;
    if (loud) _lastLoud = t;

    if (_recording) {
      final protectedUntil = _protectedUntil;
      final inBurst = protectedUntil != null && t.isBefore(protectedUntil);
      _charge(inBurst ? _burstUsed : _regularUsed, t, frame);
    }

    if (burstOnset && _burstCapLeft(t)) {
      final until = t.add(settings.burstClip);
      final current = _protectedUntil;
      if (current == null || until.isAfter(current)) _protectedUntil = until;
      if (!_recording) return _start(ClipKind.burst);
      return PolicyAction.none;
    }

    if (!_recording) {
      if (loud && _budgetLeft(t)) return _start(ClipKind.threshold);
      return PolicyAction.none;
    }

    final protectedUntil = _protectedUntil;
    if (protectedUntil != null && t.isBefore(protectedUntil)) {
      if (_burstCapLeft(t)) return PolicyAction.none;
    }
    if (!_budgetLeft(t)) return _stop();
    final lastLoud = _lastLoud;
    if (lastLoud == null || t.difference(lastLoud) >= settings.hangover) {
      return _stop();
    }
    return PolicyAction.none;
  }

  PolicyAction _start(ClipKind kind) {
    _recording = true;
    _kind = kind;
    return PolicyAction.start;
  }

  PolicyAction _stop() {
    _recording = false;
    _kind = null;
    _protectedUntil = null;
    return PolicyAction.stop;
  }

  static DateTime _hour(DateTime t) => DateTime(t.year, t.month, t.day, t.hour);

  static void _charge(Map<DateTime, Duration> m, DateTime t, Duration d) {
    final h = _hour(t);
    m[h] = (m[h] ?? Duration.zero) + d;
  }
}
