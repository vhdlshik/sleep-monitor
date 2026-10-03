import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:intl/intl.dart';
import 'package:record/record.dart';

import '../analysis/level.dart';
import '../analysis/night_analyzer.dart';
import '../analysis/snore_classifier.dart';
import '../models.dart';
import '../recording/recording_policy.dart';
import '../recording/wav_writer.dart';
import '../storage/session_store.dart';

/// Live state shown while a night is being monitored.
class LiveState {
  const LiveState({
    this.levelDb = minDb,
    this.floorDb = minDb,
    this.recording = false,
    this.events = 0,
    this.clips = 0,
  });

  final double levelDb;
  final double floorDb;
  final bool recording;
  final int events;
  final int clips;
}

/// Runs a night: microphone stream, analysis, clip files and saving.
///
/// A foreground service with the microphone type keeps the process (and so
/// this isolate) alive with the screen off.
class NightMonitor {
  NightMonitor(this.store);

  final SessionStore store;

  static const sampleRate = 16000;
  static const frame = Duration(milliseconds: 100);
  static const _frameBytes = sampleRate * 2 * 100 ~/ 1000;
  static const _saveEvery = Duration(minutes: 1);

  final ValueNotifier<LiveState?> live = ValueNotifier(null);

  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _sub;
  NightSession? _night;
  NightAnalyzer? _analyzer;
  PreRollBuffer? _preRoll;
  WavWriter? _writer;
  String? _clipFile;
  DateTime? _clipStart;
  ClipKind? _clipKind;
  int _frameIndex = 0;
  DateTime? _lastSave;
  final BytesBuilder _pending = BytesBuilder(copy: false);
  Future<void> _queue = Future.value();

  bool get isRunning => _night != null;

  static void initService() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'night_monitor',
        channelName: 'Night monitoring',
        channelDescription: 'Shown while the microphone is listening.',
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
      ),
    );
  }

  /// Starts monitoring. Returns an error message, or null on success.
  Future<String?> start(MonitorSettings settings) async {
    if (isRunning) return null;
    final recorder = AudioRecorder();
    if (!await recorder.hasPermission()) {
      await recorder.dispose();
      return 'Microphone permission is needed to monitor the night.';
    }
    if (await FlutterForegroundTask.checkNotificationPermission() !=
        NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    final service = await FlutterForegroundTask.startService(
      serviceTypes: [ForegroundServiceTypes.microphone],
      notificationTitle: 'Sleep monitor is listening',
      notificationText: 'Tap to open. Stop it in the app in the morning.',
    );
    if (service is ServiceRequestFailure) {
      await recorder.dispose();
      return 'Could not start background monitoring: ${service.error}';
    }

    await store.purgeOlderThan(settings.retention);
    final now = DateTime.now();
    final night = NightSession(
      id: DateFormat('yyyyMMdd-HHmmss').format(now),
      start: now,
    );
    await store.create(night.id);

    _recorder = recorder;
    _night = night;
    _analyzer = NightAnalyzer(settings);
    _preRoll = PreRollBuffer(
      settings.preRoll.inMilliseconds ~/ frame.inMilliseconds,
    );
    _frameIndex = 0;
    _lastSave = now;
    live.value = const LiveState();

    final stream = await recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
        // Raw levels: gain control would hide the very changes we look for.
        autoGain: false,
        echoCancel: false,
        noiseSuppress: false,
      ),
    );
    _sub = stream.listen((chunk) {
      _queue = _queue.then((_) => _onChunk(chunk));
    });
    return null;
  }

  /// Stops monitoring and saves the night. Returns the saved night.
  Future<NightSession?> stop() async {
    final night = _night;
    if (night == null) return null;
    await _sub?.cancel();
    await _recorder?.stop();
    await _recorder?.dispose();
    await _queue;
    final end = _frameTime(_frameIndex);
    await _closeClip(end);
    _analyzer!.finish();
    night.end = end;
    await _save();
    await FlutterForegroundTask.stopService();

    _sub = null;
    _recorder = null;
    _night = null;
    _analyzer = null;
    _preRoll = null;
    _pending.clear();
    live.value = null;
    return night;
  }

  DateTime _frameTime(int index) => _night!.start.add(frame * index);

  Future<void> _onChunk(Uint8List chunk) async {
    if (_night == null) return;
    _pending.add(chunk);
    if (_pending.length < _frameBytes) return;
    final bytes = _pending.takeBytes();
    var offset = 0;
    while (bytes.length - offset >= _frameBytes) {
      await _onFrame(
        Uint8List.sublistView(bytes, offset, offset + _frameBytes),
      );
      offset += _frameBytes;
    }
    if (offset < bytes.length) _pending.add(bytes.sublist(offset));
  }

  Future<void> _onFrame(Uint8List pcm) async {
    final t = _frameTime(_frameIndex++);
    final samples = Int16List.view(
      Uint8List.fromList(pcm).buffer,
      0,
      pcm.length ~/ 2,
    );
    final level = pcm16Dbfs(samples);
    final analyzer = _analyzer!;
    final result = analyzer.process(t, level);

    switch (result.action) {
      case PolicyAction.start:
        await _openClip(t, analyzer.policy.kind ?? ClipKind.threshold);
        await _writer!.add(pcm);
      case PolicyAction.stop:
        await _writer?.add(pcm);
        await _closeClip(t.add(frame));
        _preRoll!.add(pcm);
      case PolicyAction.none:
        if (_writer != null) {
          await _writer!.add(pcm);
        } else {
          _preRoll!.add(pcm);
        }
    }

    live.value = LiveState(
      levelDb: level,
      floorDb: result.floorDb,
      recording: _writer != null,
      events: analyzer.events.length,
      clips: _night!.clips.length,
    );

    if (t.difference(_lastSave!) >= _saveEvery) {
      _lastSave = t;
      await _save();
    }
  }

  Future<void> _openClip(DateTime t, ClipKind kind) async {
    final night = _night!;
    final pre = _preRoll!.drain();
    final start = t.subtract(frame * pre.length);
    final file = 'clip-${DateFormat('HHmmss').format(start)}-${kind.name}.wav';
    final writer = await WavWriter.open(
      store.clipPath(night.id, file),
      sampleRate: sampleRate,
    );
    for (final f in pre) {
      await writer.add(f);
    }
    _writer = writer;
    _clipFile = file;
    _clipStart = start;
    _clipKind = kind;
  }

  Future<void> _closeClip(DateTime end) async {
    final writer = _writer;
    if (writer == null) return;
    await writer.close();
    _night!.clips.add(
      Clip(file: _clipFile!, start: _clipStart!, end: end, kind: _clipKind!),
    );
    _writer = null;
  }

  Future<void> _save() async {
    final night = _night!;
    final analyzer = _analyzer!;
    classifySnores(analyzer.events);
    night.epochs
      ..clear()
      ..addAll(analyzer.epochs);
    night.events
      ..clear()
      ..addAll(analyzer.events);
    await store.save(night);
  }
}
