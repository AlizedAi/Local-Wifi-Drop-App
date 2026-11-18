import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';


enum AppLogLevel { info, warning, error, success }

class AppLogEntry {
  const AppLogEntry({
    required this.time,
    required this.level,
    required this.category,
    required this.message,
  });

  final DateTime time;
  final AppLogLevel level;
  final String category;
  final String message;

  String get formatted {
    final stamp = '${time.year.toString().padLeft(4, '0')}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} '
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}.${time.millisecond.toString().padLeft(3, '0')}';
    return '[$stamp] [${level.name.toUpperCase()}] [$category] $message';
  }

  Map<String, Object> toJson() => {
    'time': time.toIso8601String(),
    'level': level.name,
    'category': category,
    'message': message,
  };

  factory AppLogEntry.fromJson(Map<String, dynamic> json) => AppLogEntry(
    time: DateTime.parse(json['time'] as String),
    level: AppLogLevel.values.firstWhere((value) => value.name == json['level']),
    category: json['category'] as String,
    message: json['message'] as String,
  );
}

/// App-wide diagnostic log. Entries are stored only in app-private storage.
class AppLogController extends ChangeNotifier {
  AppLogController._()
      : _readStored = _readPrivateData,
        _writePrivate = _savePrivateData;

  static Future<String?> _readPrivateData() =>
      FlutterForegroundTask.getData<String>(key: _storageKey);

  static Future<void> _savePrivateData(String snapshot) async {
    await FlutterForegroundTask.saveData(key: _storageKey, value: snapshot);
  }

  @visibleForTesting
  AppLogController.test({
    required Future<String?> Function() readStored,
    required Future<void> Function(String snapshot) writePrivate,
  })  : _readStored = readStored,
        _writePrivate = writePrivate;

  static final AppLogController instance = AppLogController._();

  static const int maxEntries = 3000;
  static const String _storageKey = 'local_wifi_drop_system_log';
  final List<AppLogEntry> _entries = [];
  bool _persistenceEnabled = false;
  bool _persistencePending = false;
  bool _persistenceRunning = false;
  Future<void> _writeQueue = Future<void>.value();

  final Future<String?> Function() _readStored;
  final Future<void> Function(String snapshot) _writePrivate;

  @visibleForTesting
  Future<void> get pendingWrites => _writeQueue;

  List<AppLogEntry> get entries => List.unmodifiable(_entries);

  Future<void> restore() async {
    String? stored;
    try {
      stored = await _readStored();
    } catch (_) {
      // Keep current-session events if private storage is unavailable.
    }

    // Take this snapshot after the asynchronous read. Events recorded while
    // storage is being read must not be overwritten by the restored history.
    final currentSessionEntries = List<AppLogEntry>.of(_entries);
    if (stored != null && stored.isNotEmpty) {
      try {
        final decoded = jsonDecode(stored);
        if (decoded is List) {
          final restored = <AppLogEntry>[];
          for (final value in decoded) {
            if (value is! Map) continue;
            try {
              restored.add(
                AppLogEntry.fromJson(Map<String, dynamic>.from(value)),
              );
            } catch (_) {
              // Ignore a damaged entry without discarding valid history.
            }
          }
          _entries
            ..clear()
            ..addAll(restored)
            ..addAll(currentSessionEntries)
            ..sort((left, right) => left.time.compareTo(right.time));
        }
      } catch (_) {
        // Keep current-session events if the stored document is corrupt.
      }
    }
    _trim();
    _persistenceEnabled = true;
    notifyListeners();
    await _persist();
  }

  void record(String category, String message, {AppLogLevel level = AppLogLevel.info}) {
    _entries.add(AppLogEntry(
      time: DateTime.now(),
      level: level,
      category: category,
      message: message,
    ));
    _trim();
    notifyListeners();
    if (_persistenceEnabled) unawaited(_persist());
  }

  void _trim() {
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
  }

  Future<void> _persist() {
    // Keep only a dirty flag while a write is active. The next snapshot is
    // created after that write finishes, so bursts of progress events cannot
    // build an unbounded queue of large, obsolete JSON documents.
    _persistencePending = true;
    if (!_persistenceRunning) {
      _persistenceRunning = true;
      _writeQueue = _drainPersistenceQueue();
    }
    return _writeQueue;
  }

  Future<void> _drainPersistenceQueue() async {
    while (_persistencePending) {
      _persistencePending = false;
      final snapshot = jsonEncode(_entries.map((entry) => entry.toJson()).toList());
      try {
        await _writePrivate(snapshot);
      } catch (_) {
        // Private persistence is best-effort and must never interrupt transfers.
      }
    }
    _persistenceRunning = false;
  }

  void clear() {
    _entries.clear();
    notifyListeners();
    if (_persistenceEnabled) unawaited(_persist());
  }
}
