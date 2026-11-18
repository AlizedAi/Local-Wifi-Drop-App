import 'package:flutter/foundation.dart';

import 'transfer_alert.dart';
import 'app_log_controller.dart';
import 'transfer_alert_history.dart';

/// App-lifetime bridge between transfer sessions and the visible history UI.
class TransferAlertController extends ChangeNotifier {
  TransferAlertController({TransferAlertHistory? history})
      : _history = history ?? TransferAlertHistory();

  final TransferAlertHistory _history;
  bool _hasUnreadAlert = false;

  bool get hasUnreadAlert => _hasUnreadAlert;

  void markAlertsViewed() {
    if (!_hasUnreadAlert) return;
    _hasUnreadAlert = false;
    notifyListeners();
  }

  List<TransferAlert> get items => _history.items;

  /// Direction-aware callbacks for sender and receiver sessions.
  void Function(TransferAlert) get onSendAlert => (alert) => add(
        TransferAlert(fileName: alert.fileName, status: alert.status, direction: TransferDirection.send),
      );
  void Function(TransferAlert) get onReceiveAlert => (alert) => add(
        TransferAlert(fileName: alert.fileName, status: alert.status, direction: TransferDirection.receive),
      );

  /// Backwards-compatible callback; defaults to the send list.
  void Function(TransferAlert) get onAlert => onSendAlert;

  void add(TransferAlert alert) {
    _history.add(alert);
    _hasUnreadAlert = true;
    final direction = alert.direction == TransferDirection.send ? 'SEND' : 'RECEIVE';
    final level = alert.succeeded ? AppLogLevel.success : alert.status == TransferAlertStatus.failed ? AppLogLevel.error : AppLogLevel.warning;
    AppLogController.instance.record(direction, '${alert.fileName}: ${alert.status.name.toUpperCase()}', level: level);
    notifyListeners();
  }

  void addAll(Iterable<TransferAlert> alerts) {
    final incoming = alerts.toList(growable: false);
    if (incoming.isNotEmpty) _hasUnreadAlert = true;
    _history.addAll(incoming);
    notifyListeners();
  }

  void clear() {
    if (_history.items.isNotEmpty) {
      AppLogController.instance.record('HISTORY', 'Transfer history cleared');
    }
    _history.clear();
    _hasUnreadAlert = false;
    notifyListeners();
  }
}
