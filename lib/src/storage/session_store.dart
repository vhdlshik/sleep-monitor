import 'dart:convert';
import 'dart:io';

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
