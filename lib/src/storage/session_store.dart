import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models.dart';

/// Keeps each night in its own folder: `<root>/<id>/night.json` plus WAVs.
/// Everything stays on the device.
class SessionStore {
  SessionStore(this.root);

  final Directory root;

  static const _fileName = 'night.json';

  Directory dirFor(String id) => Directory('${root.path}/$id');

  String clipPath(String id, String file) => '${dirFor(id).path}/$file';

  Future<Directory> create(String id) => dirFor(id).create(recursive: true);

  Future<void> save(NightSession night) async {
    final dir = await create(night.id);
    final tmp = File('${dir.path}/$_fileName.tmp');
    await tmp.writeAsString(jsonEncode(night.toJson()), flush: true);
    await tmp.rename('${dir.path}/$_fileName');
  }

  Future<NightSession?> load(String id) async {
    final f = File('${dirFor(id).path}/$_fileName');
    if (!await f.exists()) return null;
    try {
      return NightSession.fromJson(
        (jsonDecode(await f.readAsString()) as Map).cast(),
      );
    } on FormatException {
      return null;
    }
  }

  /// Makes every recording of [night] playable: WAVs whose header was
  /// never finished (the app was killed mid-clip) get it fixed from the file
  /// size, and WAVs missing from the night's list are added back. Don't call
  /// it on the night being recorded. Returns whether anything changed.
  Future<bool> recoverClips(NightSession night) async {
    final dir = dirFor(night.id);
    if (!await dir.exists()) return false;
    final known = {for (final c in night.clips) c.file};
    var changed = false;
    await for (final entry in dir.list()) {
      if (entry is! File || !entry.path.endsWith('.wav')) continue;
      final name = entry.uri.pathSegments.last;
      final info = await repairWavHeader(entry);
      if (info == null || known.contains(name)) continue;
      final clip = _clipFromFile(night, name, info);
      if (clip == null) continue;
      night.clips.add(clip);
      changed = true;
    }
    if (changed) {
      night.clips.sort((a, b) => a.start.compareTo(b.start));
      await save(night);
    }
    return changed;
  }

  static final _clipName = RegExp(
    r'^clip-(\d\d)(\d\d)(\d\d)(?:-(\d{3}))?-(\w+)\.wav$',
  );

  /// Rebuilds a clip entry from a file name like `clip-023015-120-burst.wav`.
  static Clip? _clipFromFile(NightSession night, String name, WavInfo info) {
    final m = _clipName.firstMatch(name);
    final kind = ClipKind.values.asNameMap()[m?.group(5)];
    if (m == null || kind == null) return null;
    final s = night.start;
    var start = DateTime(
      s.year,
      s.month,
      s.day,
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
      int.parse(m.group(4) ?? '0'),
    );
    // Pre-roll can put a clip slightly before the night's start; anything
    // earlier than that is after midnight.
    if (start.isBefore(s.subtract(const Duration(minutes: 1)))) {
      start = start.add(const Duration(days: 1));
    }
    return Clip(
      file: name,
      start: start,
      end: start.add(info.duration),
      kind: kind,
    );
  }

  /// All saved nights, newest first.
  Future<List<NightSession>> list() async {
    if (!await root.exists()) return [];
    final nights = <NightSession>[];
    await for (final entry in root.list()) {
      if (entry is! Directory) continue;
      final night = await load(
        entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty),
      );
      if (night != null) nights.add(night);
    }
    nights.sort((a, b) => b.start.compareTo(a.start));
    return nights;
  }

  /// Deletes nights that started before [now] minus [retention], including
  /// their recordings. Returns the ids removed.
  Future<List<String>> purgeOlderThan(
    Duration retention, {
    DateTime? now,
  }) async {
    final cutoff = (now ?? DateTime.now()).subtract(retention);
    final removed = <String>[];
    for (final night in await list()) {
      if (night.start.isBefore(cutoff)) {
        await dirFor(night.id).delete(recursive: true);
        removed.add(night.id);
      }
    }
    return removed;
  }
}

/// Format of a 16-bit PCM WAV file.
class WavInfo {
  const WavInfo(this.sampleRate, this.dataBytes);

  final int sampleRate;
  final int dataBytes;

  Duration get duration => Duration(
    microseconds: sampleRate == 0 ? 0 : dataBytes * 500000 ~/ sampleRate,
  );
}

/// Makes the sizes in [file]'s WAV header match its length, so players don't
/// see an empty recording. Returns null for files that aren't our WAVs.
Future<WavInfo?> repairWavHeader(File file) async {
  final raf = await file.open(mode: FileMode.append);
  try {
    final length = await raf.length();
    if (length < 44) return null;
    await raf.setPosition(0);
    final bytes = await raf.read(44);
    if (String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF') return null;
    final header = ByteData.sublistView(bytes);
    final dataBytes = (length - 44) & ~1;
    if (header.getUint32(40, Endian.little) != dataBytes) {
      final fix = ByteData(4)..setUint32(0, 36 + dataBytes, Endian.little);
      await raf.setPosition(4);
      await raf.writeFrom(fix.buffer.asUint8List());
      fix.setUint32(0, dataBytes, Endian.little);
      await raf.setPosition(40);
      await raf.writeFrom(fix.buffer.asUint8List());
    }
    return WavInfo(header.getUint32(24, Endian.little), dataBytes);
  } finally {
    await raf.close();
  }
}
