import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_wifi_drop/src/app_log_controller.dart';

void main() {
  group('AppLogController', () {
    final log = AppLogController.instance;

    setUp(() => log.clear());

    test('records timestamped entries in chronological order', () {
      log.record('UI', 'Button pressed');
      log.record('NETWORK', 'Peer scan started');

      expect(log.entries, hasLength(2));
      expect(log.entries.first.category, 'UI');
      expect(log.entries.last.category, 'NETWORK');
      expect(log.entries.first.formatted, contains('[INFO] [UI] Button pressed'));
      expect(log.entries.first.formatted, matches(RegExp(r'^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}\]')));
    });

    test('retains only the newest entries when capacity is exceeded', () {
      for (var i = 0; i < AppLogController.maxEntries + 2; i++) {
        log.record('TEST', 'event-$i');
      }

      expect(log.entries, hasLength(AppLogController.maxEntries));
      expect(log.entries.first.message, 'event-2');
      expect(log.entries.last.message, 'event-${AppLogController.maxEntries + 1}');
    });

    test('formats every severity level', () {
      log.record('APP', 'started');
      log.record('NETWORK', 'slow response', level: AppLogLevel.warning);
      log.record('TRANSFER', 'failed', level: AppLogLevel.error);
      log.record('TRANSFER', 'completed', level: AppLogLevel.success);

      expect(log.entries[0].formatted, contains('[INFO] [APP] started'));
      expect(log.entries[1].formatted, contains('[WARNING] [NETWORK] slow response'));
      expect(log.entries[2].formatted, contains('[ERROR] [TRANSFER] failed'));
      expect(log.entries[3].formatted, contains('[SUCCESS] [TRANSFER] completed'));
    });

    test('notifies listeners when entries are added and cleared', () {
      var notifications = 0;
      void listener() => notifications++;
      log.addListener(listener);

      log.record('UI', 'action');
      expect(notifications, 1);

      log.clear();
      expect(notifications, 2);
      expect(log.entries, isEmpty);

      log.removeListener(listener);
    });

 
    test('restore keeps events recorded while saved history is loading', () async {
      final stored = Completer<String?>();
      final log = AppLogController.test(
        readStored: () => stored.future,
        writePrivate: (_) async {},
        writePublic: (_) async {},
      );

      final restoring = log.restore();
      log.record('UI', 'recorded during restore');
      stored.complete(jsonEncode([
        {
          'time': DateTime(2026, 1, 1).toIso8601String(),
          'level': 'info',
          'category': 'SAVED',
          'message': 'previous session',
        },
      ]));

      await restoring;
      expect(log.entries.map((entry) => entry.message), [
        'previous session',
        'recorded during restore',
      ]);
    });

    test('restore skips a malformed record but keeps valid saved entries', () async {
      final log = AppLogController.test(
        readStored: () async => jsonEncode([
          {
            'time': DateTime(2026, 1, 1).toIso8601String(),
            'level': 'info',
            'category': 'SAVED',
            'message': 'valid entry',
          },
          {
            'time': 'not-a-date',
            'level': 'unknown',
            'category': 'BROKEN',
            'message': 'bad entry',
          },
        ]),
        writePrivate: (_) async {},
        writePublic: (_) async {},
      );

      await log.restore();
      expect(log.entries, hasLength(1));
      expect(log.entries.single.message, 'valid entry');
    });

    test('coalesces persistence while a storage write is in progress', () async {
      final firstWriteStarted = Completer<void>();
      final releaseFirstWrite = Completer<void>();
      final snapshots = <String>[];
      final log = AppLogController.test(
        readStored: () async => null,
        writePrivate: (snapshot) async {
          snapshots.add(snapshot);
          if (!firstWriteStarted.isCompleted) {
            firstWriteStarted.complete();
            await releaseFirstWrite.future;
          }
        },
        writePublic: (_) async {},
      );

      final restoring = log.restore();
      await firstWriteStarted.future;
      log.record('TEST', 'first');
      log.record('TEST', 'second');
      log.record('TEST', 'third');
      releaseFirstWrite.complete();
      await restoring;

      expect(snapshots, hasLength(2));
      final persisted = (jsonDecode(snapshots.last) as List)
          .cast<Map<String, dynamic>>();
      expect(persisted.map((entry) => entry['message']), [
        'first',
        'second',
        'third',
      ]);
    });

    test('clear removes all entries', () {
      log.record('APP', 'started');
      log.clear();
      expect(log.entries, isEmpty);
    });
  });
}
