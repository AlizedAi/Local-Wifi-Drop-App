enum TransferAlertStatus { sent, received, rejected, cancelled, failed }
enum TransferDirection { send, receive }

/// A concise per-file event for the transfer alert/history UI.
class TransferAlert {
  const TransferAlert({
    required this.fileName,
    required this.status,
    this.direction = TransferDirection.send,
  });

  final String fileName;
  final TransferAlertStatus status;
  final TransferDirection direction;

  bool get succeeded => status == TransferAlertStatus.sent || status == TransferAlertStatus.received;
  String get displayText => '$fileName      ${status.name}';
}
