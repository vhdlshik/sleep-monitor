# Sleep monitor

A Flutter app (Android first, iOS later) that listens through the microphone
overnight, records what matters, and in the morning shows a chart of the night
with estimated sleep phases and snoring times.

## How it works

* **Background level.** The app keeps tracking the room's normal background
  noise, so all thresholds are "dB above background" and work the same on any
  phone.
* **Regular recording.** Sound above the recording threshold (adjustable,
  default 1 dB) is recorded, at most **5 minutes per clock hour**.
* **Sudden sounds are always recorded.** A sudden jump (adjustable, default
  10 dB above background) such as a snore, cough or gasp keeps a 20 s clip,
  with 3 s from before it. These clips **don't count** towards the 5 minutes.
  A separate safety cap of 15 min of burst audio per hour stops a night of
  heavy snoring from filling the phone; every burst is still timestamped.
* **Snoring.** Bursts that repeat with a breathing rhythm (at least 3, every
  2 to 10 s) are marked as snores and grouped into episodes.
* **Sleep phases.** Each 30 s of the night gets a stage (awake, REM, light,
  deep), estimated from sound only: restlessness, non-snore noises and a
  ~90 minute sleep-cycle model. It's a rough estimate; more sensors
  (motion, heart rate) are planned to improve it.
* **Privacy.** Everything stays on the phone. Nights older than 7 days are
  deleted with their recordings.

## Code

| Path | What |
| --- | --- |
| `lib/src/analysis/` | Level meter, background tracking, burst/snore detection, sleep staging |
| `lib/src/recording/` | Recording policy (threshold, hourly cap, bursts) and WAV writing |
| `lib/src/monitor/night_monitor.dart` | Microphone stream, foreground service, clip files |
| `lib/src/storage/` | Nights as JSON + WAV per folder, 7-day cleanup, settings |
| `lib/src/ui/` | Home screen, morning view and chart |

The analysis and recording rules are plain Dart with no I/O, covered by
`flutter test`.

## Run

```sh
flutter pub get
flutter test
flutter run            # with an Android phone connected
```

CI builds a debug APK on every pull request (download it from the run's
artifacts).
