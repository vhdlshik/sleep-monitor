import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path_provider/path_provider.dart';

import 'src/monitor/night_monitor.dart';
import 'src/storage/session_store.dart';
import 'src/ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  NightMonitor.initService();
  final docs = await getApplicationDocumentsDirectory();
  final store = SessionStore(Directory('${docs.path}/nights'));
  runApp(SleepMonitorApp(store: store, monitor: NightMonitor(store)));
}

class SleepMonitorApp extends StatelessWidget {
  const SleepMonitorApp({
    super.key,
    required this.store,
    required this.monitor,
  });

  final SessionStore store;
  final NightMonitor monitor;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sleep monitor',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      // Keeps the app alive in the background instead of closing on "back".
      home: WithForegroundTask(
        child: HomePage(store: store, monitor: monitor),
      ),
    );
  }
}
