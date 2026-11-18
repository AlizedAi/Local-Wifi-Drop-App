import 'transfer_alert.dart';

/// In-memory bounded history for transfer file outcomes.
///
/// Newest events are listed first. The store is intentionally process-local;
/// durable persistence can be added by the platform layer without changing
/// transfer/session code.
class TransferAlertHistory {
  TransferAlertHistory({this.capacity = 100}) {
    if (capacity < 1) {
      throw ArgumentError.value(capacity, 'capacity', 'Must be at least 1.');
    }
  }

  final int capacity;
  final List<TransferAlert> _items = [];

  List<TransferAlert> get items => List<TransferAlert>.unmodifiable(_items);

  void add(TransferAlert alert) {
    _items.insert(0, alert);
    if (_items.length > capacity) {
      _items.removeRange(capacity, _items.length);
    }
  }

  void addAll(Iterable<TransferAlert> alerts) {
    for (final alert in alerts) {
      add(alert);
    }
  }

  void clear() => _items.clear();
}
