import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../analysis/night_summary.dart';
import '../analysis/sleep_stager.dart';
import '../models.dart';
import '../storage/session_store.dart';
import 'night_chart.dart';

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
  String? _playing;

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _play(Clip clip) async {
    if (_playing == clip.file) {
      await _player.stop();
      setState(() => _playing = null);
      return;
    }
    await _player.play(
      DeviceFileSource(widget.store.clipPath(widget.night.id, clip.file)),
    );
    setState(() => _playing = clip.file);
    _player.onPlayerComplete.first.then((_) {
      if (mounted) setState(() => _playing = null);
    });
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
          Text('Snoring', style: Theme.of(context).textTheme.titleMedium),
          if (s.episodes.isEmpty) const Text('No snoring detected.'),
          for (final e in s.episodes)
            ListTile(
              dense: true,
              leading: const Icon(Icons.graphic_eq),
              title: Text('${hm.format(e.start)} – ${hm.format(e.end)}'),
              subtitle: Text('${e.count} snores'),
            ),
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
