import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../analysis/night_summary.dart';
import '../analysis/sleep_stager.dart';
import '../models.dart';
import '../storage/session_store.dart';
import 'night_chart.dart';
import 'sound_chart.dart';

/// The morning view of one night.
class NightPage extends StatefulWidget {
  const NightPage({super.key, required this.night, required this.store});

  final NightSession night;
  final SessionStore store;

  @override
  State<NightPage> createState() => _NightPageState();
}

class _NightPageState extends State<NightPage> {
  final _player = AudioPlayer();
  late final NightSummary _summary = NightSummary.of(widget.night);

  /// Which play button is playing (a clip file, a snore or a chart moment),
  /// so it alone shows a stop icon.
  String? _playing;

  @override
  void initState() {
    super.initState();
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playing = null);
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  /// Plays [clip] from [from] (its start when null), or stops it if that is
  /// what's playing already.
  Future<void> _play(Clip clip, {DateTime? from, String? key}) async {
    key ??= clip.file;
    if (_playing == key) {
      await _player.stop();
      setState(() => _playing = null);
      return;
    }
    final path = widget.store.clipPath(widget.night.id, clip.file);
    try {
      if (!await File(path).exists()) {
        throw const FileSystemException('the recording file is missing');
      }
      await _player.stop();
      // A second before the sound, so its start isn't cut off.
      var offset = from == null
          ? Duration.zero
          : from.difference(clip.start) - const Duration(seconds: 1);
      if (offset.isNegative) offset = Duration.zero;
      await _player.play(DeviceFileSource(path), position: offset);
      if (mounted) setState(() => _playing = key);
    } catch (e) {
      if (!mounted) return;
      setState(() => _playing = null);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Couldn\'t play it: $e')));
    }
  }

  /// Plays whatever was recorded at [t], from [t].
  void _playAt(DateTime t, {String? key}) {
    final clip = widget.night.clipAt(t);
    if (clip == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Nothing was recorded at ${DateFormat.Hms().format(t)}.',
          ),
        ),
      );
      return;
    }
    _play(clip, from: t, key: key ?? 'at:${t.millisecondsSinceEpoch}');
  }

  /// The first snore of [e] that was recorded.
  SoundEvent? _recordedSnore(SnoreEpisode e) {
    for (final s in widget.night.snores) {
      if (s.start.isBefore(e.start) || s.start.isAfter(e.end)) continue;
      if (widget.night.clipAt(s.start) != null) return s;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final night = widget.night;
    final hm = DateFormat.Hm();
    final s = _summary;
    return Scaffold(
      appBar: AppBar(title: Text(DateFormat.yMMMEd().format(night.start))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '${hm.format(night.start)} to ${night.end == null ? '…' : hm.format(night.end!)}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              _stat('Asleep', _dur(s.asleep)),
              _stat('Deep', _dur(s.timeIn(SleepStage.deep))),
              _stat('REM', _dur(s.timeIn(SleepStage.rem))),
              _stat('Awake', _dur(s.timeIn(SleepStage.awake))),
              _stat('Snores', '${night.snores.length}'),
            ],
          ),
          const SizedBox(height: 16),
          if (night.epochs.isEmpty)
            const Text('Not enough data for a chart yet.')
          else
            NightChart(summary: s),
          const SizedBox(height: 4),
          Text(
            'Phases are estimated from sound only. Orange marks snoring.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const Divider(height: 32),
          Text('Sound level', style: Theme.of(context).textTheme.titleMedium),
          if (night.epochs.isEmpty)
            const Text('Not enough data for a chart yet.')
          else ...[
            SoundChart(night: night, onEventTap: _playAt),
            Text(
              'Loudest sound each second, 0 dB is a whisper. Pinch or use the '
              'buttons to zoom, drag to scroll. Tap a line to hear it.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const Divider(height: 32),
          Text('Snoring', style: Theme.of(context).textTheme.titleMedium),
          if (s.episodes.isEmpty) const Text('No snoring detected.'),
          for (final e in s.episodes) _episodeTile(e),
          const Divider(height: 32),
          Text('Recordings', style: Theme.of(context).textTheme.titleMedium),
          if (night.clips.isEmpty) const Text('Nothing was recorded.'),
          for (final c in night.clips)
            ListTile(
              dense: true,
              leading: IconButton(
                icon: Icon(_playing == c.file ? Icons.stop : Icons.play_arrow),
                onPressed: () => _play(c),
              ),
              title: Text(DateFormat.Hms().format(c.start)),
              subtitle: Text(
                '${c.duration.inSeconds} s · ${c.kind == ClipKind.burst ? 'sudden sound' : 'above threshold'}',
              ),
            ),
        ],
      ),
    );
  }

  Widget _episodeTile(SnoreEpisode e) {
    final hms = DateFormat.Hms();
    final snore = _recordedSnore(e);
    final key = 'snore:${e.start.millisecondsSinceEpoch}';
    return ListTile(
      dense: true,
      leading: snore == null
          ? const Icon(Icons.graphic_eq)
          : IconButton(
              icon: Icon(_playing == key ? Icons.stop : Icons.play_arrow),
              onPressed: () => _playAt(snore.start, key: key),
            ),
      title: Text('${hms.format(e.start)} – ${hms.format(e.end)}'),
      subtitle: Text(
        '${e.count} ${e.count == 1 ? 'snore' : 'snores'}'
        '${snore == null ? ' · not recorded' : ''}',
      ),
    );
  }

  Widget _stat(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.labelSmall),
      Text(value, style: Theme.of(context).textTheme.titleLarge),
    ],
  );

  static String _dur(Duration d) =>
      '${d.inHours}h ${(d.inMinutes % 60).toString().padLeft(2, '0')}m';
}
