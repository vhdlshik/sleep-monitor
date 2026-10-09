import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_monitor/src/models.dart';
import 'package:sleep_monitor/src/recording/wav_writer.dart';
import 'package:sleep_monitor/src/storage/session_store.dart';

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('sleep'));
  tearDown(() => tmp.delete(recursive: true));

  test('nights round-trip through JSON', () async {
    final store = SessionStore(tmp);
    final night = NightSession(
      id: 'n1',
      start: DateTime(2026, 10, 2, 23),
      end: DateTime(2026, 10, 3, 7),
      epochs: [
        Epoch(
          start: DateTime(2026, 10, 2, 23),
          meanDb: -55.25,
          maxDb: -40,
          floorDb: -60,
          activeFraction: 0.1,
          bursts: 2,
        ),
      ],
      events: [
        SoundEvent(
          start: DateTime(2026, 10, 3, 2),
          duration: const Duration(milliseconds: 700),
          peakDb: -35,
          type: SoundEventType.snore,
        ),
      ],
      clips: [
        Clip(
          file: 'a.wav',
          start: DateTime(2026, 10, 3, 2),
          end: DateTime(2026, 10, 3, 2, 0, 20),
          kind: ClipKind.burst,
        ),
      ],
    );
    await store.save(night);
    final loaded = (await store.load('n1'))!;
    expect(loaded.end, night.end);
    expect(loaded.snores.length, 1);
    expect(loaded.clips.single.kind, ClipKind.burst);
    expect(loaded.epochs.single.meanDb, closeTo(-55.2, 0.11));
  });

  test('nights older than a week are deleted with their files', () async {
    final store = SessionStore(tmp);
    final now = DateTime(2026, 10, 10, 8);
    await store.save(NightSession(id: 'old', start: DateTime(2026, 10, 2, 23)));
    await store.save(NightSession(id: 'new', start: DateTime(2026, 10, 9, 23)));
    await File(store.clipPath('old', 'x.wav')).writeAsString('x');
    final removed = await store.purgeOlderThan(
      const Duration(days: 7),
      now: now,
    );
    expect(removed, ['old']);
    expect(await store.dirFor('old').exists(), isFalse);
    expect((await store.list()).single.id, 'new');
  });

  test('WAV header matches the data written', () async {
    final path = '${tmp.path}/t.wav';
    final w = await WavWriter.open(path, sampleRate: 16000);
    await w.add(Uint8List(3200));
    await w.add(Uint8List(3200));
    await w.close();
    final bytes = await File(path).readAsBytes();
    final b = ByteData.sublistView(bytes);
    expect(bytes.length, 44 + 6400);
    expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
    expect(b.getUint32(40, Endian.little), 6400);
    expect(b.getUint32(24, Endian.little), 16000);
  });

  test('per-second levels round-trip; old nights load without them', () async {
    final store = SessionStore(tmp);
    final night = NightSession(
      id: 'n2',
      start: DateTime(2026, 10, 2, 23),
      levels: LevelTrack(
        start: DateTime(2026, 10, 2, 23),
        peaks: [-60, -55.25, -30],
      ),
    );
    await store.save(night);
    final loaded = (await store.load('n2'))!;
    expect(loaded.levels!.peaks, [-60, -55.3, -30]);
    expect(loaded.levels!.end, DateTime(2026, 10, 2, 23, 0, 3));

    final json = night.toJson()..remove('levels');
    expect(NightSession.fromJson(json).levels, isNull);
  });

  test('an unfinished clip is repaired and added back to its night', () async {
    final store = SessionStore(tmp);
    final night = NightSession(id: 'n3', start: DateTime(2026, 10, 2, 23, 30));
    await store.save(night);
    // Killed mid-clip: the header still says no data.
    final w = await WavWriter.open(
      store.clipPath('n3', 'clip-021500-250-burst.wav'),
      sampleRate: 16000,
    );
    await w.add(Uint8List(64000));
    // A finished clip from before the night started (pre-roll) stays as is.
    final ok = await WavWriter.open(
      store.clipPath('n3', 'clip-232958-burst.wav'),
      sampleRate: 16000,
    );
    await ok.add(Uint8List(32000));
    await ok.close();

    expect(await store.recoverClips(night), isTrue);
    expect(night.clips.map((c) => c.start), [
      DateTime(2026, 10, 2, 23, 29, 58),
      DateTime(2026, 10, 3, 2, 15, 0, 250),
    ]);
    expect(night.clips.last.duration, const Duration(seconds: 2));
    expect(night.clips.last.kind, ClipKind.burst);
    final bytes = await File(store.clipPath('n3', 'clip-021500-250-burst.wav'))
        .readAsBytes();
    expect(ByteData.sublistView(bytes).getUint32(40, Endian.little), 64000);
    expect((await store.load('n3'))!.clips.length, 2);
    expect(await store.recoverClips(night), isFalse);
  });

  test('clipAt finds the recording around a moment', () {
    final night = NightSession(
      id: 'n4',
      start: DateTime(2026, 10, 2, 23),
      clips: [
        Clip(
          file: 'a.wav',
          start: DateTime(2026, 10, 3, 2),
          end: DateTime(2026, 10, 3, 2, 0, 20),
          kind: ClipKind.burst,
        ),
      ],
    );
    expect(night.clipAt(DateTime(2026, 10, 3, 2, 0, 5))?.file, 'a.wav');
    expect(night.clipAt(DateTime(2026, 10, 3, 2, 0, 20)), isNull);
  });

  test('pre-roll keeps only the newest frames', () {
    final p = PreRollBuffer(3);
    for (var i = 0; i < 5; i++) {
      p.add(Uint8List.fromList([i]));
    }
    expect(p.drain().map((f) => f.first), [2, 3, 4]);
    expect(p.length, 0);
  });
}
