import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models.dart';
import '../monitor/night_monitor.dart';
import '../storage/session_store.dart';
import '../storage/settings_store.dart';
import 'night_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.store, required this.monitor});

  final SessionStore store;
  final NightMonitor monitor;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _settingsStore = SettingsStore();
  MonitorSettings _settings = const MonitorSettings();
  List<NightSession> _nights = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings = await _settingsStore.load();
    await widget.store.purgeOlderThan(settings.retention);
    final nights = await widget.store.list();
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _nights = nights;
    });
  }

  Future<void> _toggle() async {
    setState(() => _busy = true);
    final monitor = widget.monitor;
    if (monitor.isRunning) {
      final night = await monitor.stop();
      await _load();
      if (mounted && night != null) _open(night);
    } else {
      final error = await monitor.start(_settings);
      if (error != null && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error)));
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  void _open(NightSession night) => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => NightPage(night: night, store: widget.store),
    ),
  );

  void _updateSettings(MonitorSettings s) {
    setState(() => _settings = s);
    _settingsStore.save(s);
  }

  @override
  Widget build(BuildContext context) {
    final running = widget.monitor.isRunning;
    return Scaffold(
      appBar: AppBar(title: const Text('Sleep monitor')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          FilledButton.icon(
            onPressed: _busy ? null : _toggle,
            icon: Icon(running ? Icons.wb_sunny : Icons.bedtime),
            label: Text(running ? 'Good morning (stop)' : 'Start night'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
            ),
          ),
          const SizedBox(height: 16),
          if (running) _LivePanel(monitor: widget.monitor),
          _SettingSlider(
            label: 'Recording threshold above background',
            value: _settings.thresholdDb,
            min: 0.5,
            max: 20,
            enabled: !running,
            onChanged: (v) =>
                _updateSettings(_settings.copyWith(thresholdDb: v)),
          ),
          _SettingSlider(
            label: 'Sudden sound (snore) sensitivity',
            value: _settings.burstDb,
            min: 4,
            max: 30,
            enabled: !running,
            onChanged: (v) => _updateSettings(_settings.copyWith(burstDb: v)),
          ),
          Text(
            'Regular recording is capped at 5 min per hour. Sudden sounds are '
            'always recorded and don\'t count. Nights older than 7 days are '
            'deleted. Everything stays on this phone.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const Divider(height: 32),
          Text('Nights', style: Theme.of(context).textTheme.titleMedium),
          if (_nights.isEmpty) const Text('No nights recorded yet.'),
          for (final n in _nights)
            ListTile(
              leading: const Icon(Icons.nights_stay),
              title: Text(DateFormat.yMMMEd().add_Hm().format(n.start)),
              subtitle: Text(
                '${n.snores.length} snores · ${n.clips.length} recordings',
              ),
              onTap: () => _open(n),
            ),
        ],
      ),
    );
  }
}

class _LivePanel extends StatelessWidget {
  const _LivePanel({required this.monitor});

  final NightMonitor monitor;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<LiveState?>(
      valueListenable: monitor.live,
      builder: (context, s, _) {
        if (s == null) return const SizedBox.shrink();
        final above = s.levelDb - s.floorDb;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Now: ${above >= 0 ? '+' : ''}${above.toStringAsFixed(1)} dB over background',
                ),
                Text('Background: ${s.floorDb.toStringAsFixed(1)} dBFS'),
                Text(s.recording ? 'Recording…' : 'Listening'),
                Text('${s.events} sudden sounds · ${s.clips} recordings'),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SettingSlider extends StatelessWidget {
  const _SettingSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final double value, min, max;
  final bool enabled;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label: ${value.toStringAsFixed(1)} dB'),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: ((max - min) * 2).round(),
          onChanged: enabled ? onChanged : null,
        ),
      ],
    );
  }
}
