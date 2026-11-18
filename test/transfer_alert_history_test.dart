import 'package:flutter_test/flutter_test.dart';
import 'package:local_wifi_drop/src/app_log_controller.dart';
import 'package:local_wifi_drop/src/transfer_alert.dart';
import 'package:local_wifi_drop/src/transfer_alert_controller.dart';
import 'package:local_wifi_drop/src/transfer_alert_history.dart';

void main() {
  test('clearing transfer history is recorded in the application Log', () {
    final appLog = AppLogController.instance;
    appLog.clear();
    final controller = TransferAlertController();
    controller.add(const TransferAlert(
      fileName: 'sample.bin',
      status: TransferAlertStatus.sent,
    ));

    appLog.clear();
    controller.clear();

    expect(appLog.entries, hasLength(1));
    expect(appLog.entries.single.category, 'HISTORY');
    expect(appLog.entries.single.message, 'Transfer history cleared');
    appLog.clear();
  });

  group('TransferAlertHistory', () {
    test('keeps newest file events first and preserves cancelled status', () {
      final history = TransferAlertHistory();
      history.add(const TransferAlert(
        fileName: 'A.MP3',
        status: TransferAlertStatus.cancelled,
      ));
      history.add(const TransferAlert(
        fileName: 'B.MP3',
        status: TransferAlertStatus.sent,
      ));

      expect(history.items.map((event) => event.displayText), [
        'B.MP3      sent',
        'A.MP3      cancelled',
      ]);
    });

    test('bounds memory by retaining only the newest configured entries', () {
      final history = TransferAlertHistory(capacity: 2);
      for (var index = 1; index <= 3; index++) {
        history.add(TransferAlert(
          fileName: 'file-$index',
          status: TransferAlertStatus.cancelled,
        ));
      }

      expect(history.items.map((event) => event.fileName), [
        'file-3',
        'file-2',
      ]);
    });

    test('exposes an immutable snapshot and supports clearing', () {
      final history = TransferAlertHistory()
        ..add(const TransferAlert(
          fileName: 'A.MP3',
          status: TransferAlertStatus.cancelled,
        ));

      expect(
        () => history.items.add(const TransferAlert(
          fileName: 'B.MP3',
          status: TransferAlertStatus.sent,
        )),
        throwsUnsupportedError,
      );
      history.clear();
      expect(history.items, isEmpty);
    });
  });
}
