import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../analysis/level.dart';
import '../models.dart';

/// Sound level for the whole night, with snores, other sudden sounds and
/// recordings drawn as vertical lines.
///
/// Pinch or use the buttons to zoom, drag to move, double-tap for the whole
/// night. Tapping near a line calls [onEventTap] with its time.
class SoundChart extends StatefulWidget {
  const SoundChart({super.key, required this.night, this.onEventTap});

  final NightSession night;
  final ValueChanged<DateTime>? onEventTap;

  @override
  State<SoundChart> createState() => _SoundChartState();
}

class _SoundChartState extends State<SoundChart> {
  static const _minSpan = 30.0; // seconds
  static const _tapSlop = 16.0; // pixels

  late final _Series _series = _Series.of(widget.night);

  // Visible window, in seconds from the series start.
  late double _from = 0, _to = _series.span;
  double _gestureFrom = 0, _gestureTo = 0, _gestureX = 0;
  double _width = 1;

  double get _full => _series.span;

  void _setWindow(double from, double to) {
    final span = (to - from).clamp(math.min(_minSpan, _full), _full);
    final start = from.clamp(0.0, _full - span);
    setState(() {
      _from = start;
      _to = start + span;
    });
  }

  /// Zooms by [factor] (>1 zooms in) around the middle.
  void _zoom(double factor) {
    final mid = (_from + _to) / 2, span = (_to - _from) / factor;
    _setWindow(mid - span / 2, mid + span / 2);
  }

  void _onTapUp(TapUpDetails d) {
    final cb = widget.onEventTap;
    if (cb == null) return;
    final secPerPx = (_to - _from) / _width;
    final t = _from + (d.localPosition.dx - _Painter.left) * secPerPx;
    // Sounds win over recording starts, which often sit a few seconds
    // before them.
    DateTime? best;
    for (final clips in [false, true]) {
      var bestDist = _tapSlop * secPerPx;
      for (final m in _series.marks) {
        if ((m.kind == _MarkKind.clip) != clips) continue;
        final dist = (m.at - t).abs();
        if (dist <= bestDist) {
          bestDist = dist;
          best = _series.timeAt(m.at);
        }
      }
      if (best != null) break;
    }
    if (best != null) cb(best);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = _Colors(
      level: scheme.secondary,
      grid: scheme.outlineVariant,
      text: scheme.onSurfaceVariant,
      snore: Colors.orange,
      burst: scheme.error,
      clip: scheme.primary,
    );
    final whole = _to - _from >= _full - 0.5;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _rangeLabel(),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            IconButton(
              tooltip: 'Zoom out',
              icon: const Icon(Icons.zoom_out),
              onPressed: whole ? null : () => _zoom(0.5),
            ),
            IconButton(
              tooltip: 'Zoom in',
              icon: const Icon(Icons.zoom_in),
              onPressed: _to - _from <= _minSpan ? null : () => _zoom(2),
            ),
            IconButton(
              tooltip: 'Whole night',
              icon: const Icon(Icons.fit_screen),
              onPressed: whole ? null : () => _setWindow(0, _full),
            ),
          ],
        ),
        SizedBox(
          height: 200,
          child: LayoutBuilder(
            builder: (context, box) {
              _width = math.max(1, box.maxWidth - _Painter.left);
              return GestureDetector(
                onTapUp: _onTapUp,
                onDoubleTap: () => _setWindow(0, _full),
                onScaleStart: (d) {
                  _gestureFrom = _from;
                  _gestureTo = _to;
                  _gestureX = d.localFocalPoint.dx - _Painter.left;
                },
                onScaleUpdate: (d) {
                  // Keep the time first under the fingers under them as they
                  // pinch (zoom) and move (pan).
                  final span = _gestureTo - _gestureFrom;
                  final focus = _gestureFrom + span * _gestureX / _width;
                  final scale = d.horizontalScale > 0 ? d.horizontalScale : 1;
                  final newSpan = span / scale;
                  final x = d.localFocalPoint.dx - _Painter.left;
                  final from = focus - newSpan * x / _width;
                  _setWindow(from, from + newSpan);
                },
                child: CustomPaint(
                  size: Size.infinite,
                  painter: _Painter(_series, _from, _to, colors),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            _legend(colors.snore, 'Snore'),
            _legend(colors.burst, 'Other sudden sound'),
            _legend(colors.clip, 'Recording'),
          ],
        ),
      ],
    );
  }

  String _rangeLabel() {
    final a = _series.timeAt(_from), b = _series.timeAt(_to);
    final fmt = _to - _from < 600 ? DateFormat.Hms() : DateFormat.Hm();
    return '${fmt.format(a)} – ${fmt.format(b)}';
  }

  Widget _legend(Color c, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(width: 3, height: 12, color: c),
      const SizedBox(width: 4),
      Text(label, style: Theme.of(context).textTheme.bodySmall),
    ],
  );
}

enum _MarkKind { snore, burst, clip }

class _Mark {
  const _Mark(this.at, this.kind, [this.until]);

  /// Seconds from the series start.
  final double at;
  final _MarkKind kind;

  /// End of a recording.
  final double? until;
}

/// Night data turned into seconds from the start, which is what the chart
/// works in.
class _Series {
  _Series(this.start, this.step, this.peaks, this.span, this.marks);

  factory _Series.of(NightSession night) {
    final track = night.levels;
    final DateTime start;
    final double step;
    final List<double> peaks;
    if (track != null && track.peaks.isNotEmpty) {
      start = track.start;
      step = track.step.inMilliseconds / 1000;
      peaks = track.peaks;
    } else {
      // Nights from before the per-second track: 30 s epochs.
      final epochs = night.epochs;
      start = epochs.isEmpty ? night.start : epochs.first.start;
      step = epochs.length > 1
          ? epochs[1].start.difference(epochs[0].start).inMilliseconds / 1000
          : 30;
      peaks = [for (final e in epochs) e.maxDb];
    }
    double sec(DateTime t) => t.difference(start).inMilliseconds / 1000;
    final end = night.end;
    final span = math.max(
      1.0,
      math.max(peaks.length * step, end == null ? 0.0 : sec(end)),
    );
    final marks = [
      for (final c in night.clips)
        _Mark(sec(c.start), _MarkKind.clip, sec(c.end)),
      for (final e in night.events)
        _Mark(
          sec(e.start),
          e.type == SoundEventType.snore ? _MarkKind.snore : _MarkKind.burst,
        ),
    ];
    return _Series(start, step, peaks, span, marks);
  }

  final DateTime start;
  final double step;
  final List<double> peaks;
  final double span;
  final List<_Mark> marks;

  DateTime timeAt(double s) =>
      start.add(Duration(milliseconds: (s * 1000).round()));
}

class _Colors {
  const _Colors({
    required this.level,
    required this.grid,
    required this.text,
    required this.snore,
    required this.burst,
    required this.clip,
  });

  final Color level, grid, text, snore, burst, clip;
}

class _Painter extends CustomPainter {
  _Painter(this.s, this.from, this.to, this.c);

  final _Series s;
  final double from, to;
  final _Colors c;

  static const left = 32.0, bottom = 18.0;

  // Sound scale shown, 0 dB is a whisper.
  static const _maxDb = 80.0;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width - left, h = size.height - bottom;
    final secPerPx = (to - from) / w;
    double x(double sec) => left + (sec - from) / secPerPx;
    double y(double db) => h * (1 - (db / _maxDb).clamp(0.0, 1.0));

    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width, size.height));

    final gridPaint = Paint()
      ..color = c.grid
      ..strokeWidth = 0.5;
    for (var db = 0.0; db <= _maxDb; db += 20) {
      canvas.drawLine(
        Offset(left, y(db)),
        Offset(size.width, y(db)),
        gridPaint,
      );
      _text(canvas, '${db.round()}', Offset(0, y(db) - 7));
    }
    _timeTicks(canvas, size, x, gridPaint);

    canvas.save();
    canvas.clipRect(Rect.fromLTWH(left, 0, w, h));

    // Recordings as shaded spans under everything else.
    for (final m in s.marks) {
      if (m.kind != _MarkKind.clip) continue;
      final l = x(m.at), r = math.max(x(m.until!), l + 1);
      if (r < left || l > size.width) continue;
      canvas.drawRect(
        Rect.fromLTRB(l, 0, r, h),
        Paint()..color = c.clip.withValues(alpha: 0.12),
      );
    }

    // Loudest level in each pixel column, as a filled envelope.
    final path = Path()..moveTo(left, h);
    for (var px = 0; px <= w.ceil(); px++) {
      final a = ((from + px * secPerPx) / s.step).floor();
      final b = ((from + (px + 1) * secPerPx) / s.step).ceil();
      var peak = minDb;
      for (var i = math.max(0, a); i < math.min(b, s.peaks.length); i++) {
        if (s.peaks[i] > peak) peak = s.peaks[i];
      }
      path.lineTo(left + px, y(soundDb(peak)));
    }
    path
      ..lineTo(left + w.ceil(), h)
      ..close();
    canvas.drawPath(path, Paint()..color = c.level.withValues(alpha: 0.35));
    canvas.drawPath(
      path,
      Paint()
        ..color = c.level
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    // Event lines on top: recording starts, then sudden sounds, then snores.
    for (final kind in [_MarkKind.clip, _MarkKind.burst, _MarkKind.snore]) {
      final paint = Paint()
        ..color = switch (kind) {
          _MarkKind.clip => c.clip,
          _MarkKind.burst => c.burst,
          _MarkKind.snore => c.snore,
        }
        ..strokeWidth = kind == _MarkKind.snore ? 1.5 : 1;
      for (final m in s.marks) {
        if (m.kind != kind) continue;
        final mx = x(m.at);
        if (mx < left - 2 || mx > size.width + 2) continue;
        canvas.drawLine(Offset(mx, 0), Offset(mx, h), paint);
      }
    }
    canvas.restore();
    canvas.restore();
  }

  static const _steps = [
    1, 5, 10, 30, 60, 300, 600, 900, 1800, 3600, 7200, //
  ];

  void _timeTicks(
    Canvas canvas,
    Size size,
    double Function(double) x,
    Paint gridPaint,
  ) {
    final w = size.width - left;
    final step = _steps.firstWhere(
      (st) => st * w / (to - from) >= 70,
      orElse: () => _steps.last,
    );
    final fmt = step < 60 ? DateFormat.Hms() : DateFormat.Hm();
    // Align ticks to the wall clock, not to the start of the night.
    final startOfDay = DateTime(s.start.year, s.start.month, s.start.day);
    final offset = s.start.difference(startOfDay).inMilliseconds / 1000;
    var tick = ((from + offset) / step).ceil() * step - offset;
    while (tick <= to) {
      final tx = x(tick);
      canvas.drawLine(
        Offset(tx, 0),
        Offset(tx, size.height - bottom),
        gridPaint,
      );
      final label = fmt.format(s.timeAt(tick));
      _text(
        canvas,
        label,
        Offset(tx - label.length * 3, size.height - bottom + 3),
      );
      tick += step;
    }
  }

  void _text(Canvas canvas, String str, Offset at) {
    final tp = TextPainter(
      text: TextSpan(
        text: str,
        style: TextStyle(color: c.text, fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(_Painter old) =>
      old.from != from || old.to != to || old.s != s || old.c != c;
}
