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

  test('pre-roll keeps only the newest frames', () {
    final p = PreRollBuffer(3);
    for (var i = 0; i < 5; i++) {
      p.add(Uint8List.fromList([i]));
    }
    expect(p.drain().map((f) => f.first), [2, 3, 4]);
    expect(p.length, 0);
  });
}
