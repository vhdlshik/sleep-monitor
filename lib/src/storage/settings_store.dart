import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';

/// Persists the user-adjustable parts of [MonitorSettings].
class SettingsStore {
  static const _threshold = 'thresholdDb';
  static const _burst = 'burstDb';

  Future<MonitorSettings> load() async {
    final p = await SharedPreferences.getInstance();
    const d = MonitorSettings();
    return d.copyWith(
      thresholdDb: p.getDouble(_threshold) ?? d.thresholdDb,
      burstDb: p.getDouble(_burst) ?? d.burstDb,
    );
  }

  Future<void> save(MonitorSettings s) async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_threshold, s.thresholdDb);
    await p.setDouble(_burst, s.burstDb);
  }
}
