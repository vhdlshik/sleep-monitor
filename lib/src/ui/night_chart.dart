import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../analysis/level.dart';
import '../analysis/night_summary.dart';
import '../analysis/sleep_stager.dart';

/// Hypnogram on top, sound level below, snores marked on both.
class NightChart extends StatelessWidget {
  const NightChart({super.key, required this.summary});

  final NightSummary summary;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AspectRatio(
      aspectRatio: 1.6,
      child: CustomPaint(
        painter: _NightPainter(
          summary,
          colors: {
            SleepStage.awake: scheme.error,
            SleepStage.rem: scheme.tertiary,
            SleepStage.light: scheme.primary.withValues(alpha: 0.6),
            SleepStage.deep: scheme.primary,
          },
          grid: scheme.outlineVariant,
          text: scheme.onSurfaceVariant,
          level: scheme.secondary,
          snore: Colors.orange,
        ),
      ),
    );
  }
}

class _NightPainter extends CustomPainter {
  _NightPainter(
    this.summary, {
    required this.colors,
    required this.grid,
    required this.text,
    required this.level,
    required this.snore,
  });

  final NightSummary summary;
  final Map<SleepStage, Color> colors;
  final Color grid, text, level, snore;

  // Top to bottom, as on a clinical hypnogram.
  static const _rows = [
    SleepStage.awake,
    SleepStage.rem,
    SleepStage.light,
    SleepStage.deep,
  ];
  static const _labels = ['Awake', 'REM', 'Light', 'Deep'];
  static const _left = 44.0, _bottom = 20.0;

  @override
  void paint(Canvas canvas, Size size) {
    final epochs = summary.night.epochs;
    if (epochs.isEmpty) return;
    final t0 = epochs.first.start;
    final t1 = summary.night.end ?? epochs.last.start;
    final span = t1.difference(t0).inSeconds.clamp(1, 1 << 31);
    final w = size.width - _left;
    final hypnoH = (size.height - _bottom) * 0.62;
    final levelTop = hypnoH + 12;
    final levelH = size.height - _bottom - levelTop;
    final rowH = hypnoH / _rows.length;
    double x(DateTime t) => _left + w * t.difference(t0).inSeconds / span;

    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 0.5;
    for (var r = 0; r < _rows.length; r++) {
      final y = rowH * r + rowH / 2;
      canvas.drawLine(Offset(_left, y), Offset(size.width, y), gridPaint);
      _text(canvas, _labels[r], Offset(0, y - 7));
    }

    // Stage bars.
    for (var i = 0; i < epochs.length; i++) {
      final stage = summary.stages[i];
      final r = _rows.indexOf(stage);
      final end = i + 1 < epochs.length ? epochs[i + 1].start : t1;
      canvas.drawRect(
        Rect.fromLTRB(
          x(epochs[i].start),
          rowH * r + 2,
          x(end),
          rowH * (r + 1) - 2,
        ),
        Paint()..color = colors[stage]!,
      );
    }

    // Sound level, 0..60 dB where 0 dB is a whisper.
    final path = Path();
    for (var i = 0; i < epochs.length; i++) {
      final db = soundDb(epochs[i].meanDb).clamp(0.0, 60.0);
      final p = Offset(x(epochs[i].start), levelTop + levelH * (1 - db / 60));
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = level
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
    _text(canvas, 'Sound', Offset(0, levelTop + levelH / 2 - 7));

    // Snore episodes across both panels.
    final snorePaint = Paint()..color = snore.withValues(alpha: 0.35);
    for (final e in summary.episodes) {
      final l = x(e.start);
      final r = (x(e.end) - l < 2 ? l + 2 : x(e.end));
      canvas.drawRect(
        Rect.fromLTRB(l, levelTop, r, levelTop + levelH),
        snorePaint,
      );
    }

    // Hour ticks.
    final fmt = DateFormat.Hm();
    var tick = DateTime(t0.year, t0.month, t0.day, t0.hour + 1);
    while (!tick.isAfter(t1)) {
      final tx = x(tick);
      canvas.drawLine(
        Offset(tx, 0),
        Offset(tx, size.height - _bottom),
        gridPaint,
      );
      _text(
        canvas,
        fmt.format(tick),
        Offset(tx - 14, size.height - _bottom + 4),
      );
      tick = tick.add(const Duration(hours: 1));
    }
  }

  void _text(Canvas canvas, String s, Offset at) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(color: text, fontSize: 11),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(_NightPainter old) => old.summary != summary;
}
