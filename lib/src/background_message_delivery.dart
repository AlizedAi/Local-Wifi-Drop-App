/// Coordinates the background inbox delivery contract.
///
/// The message must be persisted before ACCEPT is sent. UI and notification
/// handoffs happen only after the acknowledgement has been sent successfully.
class BackgroundMessageDelivery {
  const BackgroundMessageDelivery({
    required this.persist,
    required this.acknowledge,
    required this.notifyMain,
    required this.showNotification,
  });

  final Future<String> Function() persist;
  final Future<void> Function() acknowledge;
  final void Function(String messageId) notifyMain;
  final Future<void> Function(String messageId) showNotification;

  Future<String> deliver() async {
    final messageId = await persist();
    await acknowledge();
    notifyMain(messageId);
    await showNotification(messageId);
    return messageId;
  }
}
