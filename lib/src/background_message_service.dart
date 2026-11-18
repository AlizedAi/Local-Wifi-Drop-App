import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter_foreground_task/flutter_foreground_task.dart' hide NotificationVisibility;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'background_message_delivery.dart';
import 'app_log_controller.dart';
import 'local_peer_discovery.dart';
import 'protocol_frame.dart';
import 'tcp_frame_connection.dart';
import 'tcp_transfer_server.dart';

/// Android-only background listener. It accepts TEXT_MESSAGE frames only;
/// file transfers remain owned by the foreground Receive screen.
@pragma('vm:entry-point')
void startBackgroundMessageTask() {
  FlutterForegroundTask.setTaskHandler(BackgroundMessageTaskHandler());
}

class BackgroundMessageTaskHandler extends TaskHandler {
  static const String _pendingMessagesKey = 'pending_incoming_messages';
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  TcpTransferServer? _server;
  LocalPeerDiscoveryResponder? _discovery;
  TcpFrameConnection? _connection;
  bool _stopping = false;
  bool _notificationReady = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    DartPluginRegistrant.ensureInitialized();
    AppLogController.instance.record('MESSAGE_RX', 'Background receiver task started');
    try {
      await _initializeNotifications();
      AppLogController.instance.record('MESSAGE_RX', 'Notification channel initialized');
    } catch (error) {
      AppLogController.instance.record('MESSAGE_RX', 'Notification setup failed; receiver will continue without notifications: $error', level: AppLogLevel.error);
    }
    unawaited(_listenForMessages());
  }

  Future<void> _initializeNotifications() async {
    if (_notificationReady) return;
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('ic_notification'),
    );
    await _notifications.initialize(settings: settings);
    const channel = AndroidNotificationChannel(
      'local_wifi_drop_incoming_messages',
      'پیام‌های دریافتی',
      description: 'اعلان پیام‌های جدید Local WiFi Drop',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
    );
    await _notifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
    _notificationReady = true;
  }

  Future<void> _listenForMessages() async {
    while (!_stopping) {
      try {
        final address = await _findWifiAddress();
        if (address == null) {
          await Future<void>.delayed(const Duration(seconds: 5));
          continue;
        }

        AppLogController.instance.record('MESSAGE_RX', 'Binding message TCP receiver to ${address.address}');
        final server = await TcpTransferServer.bind(address: address);
        _server = server;
        AppLogController.instance.record('MESSAGE_RX', 'Message TCP receiver listening on ${address.address}:${server.port}');
        final discovery = await LocalPeerDiscoveryResponder.start(
          messageHost: address.address,
          messageTcpPort: server.port,
          acceptedPurpose: 'message',
          port: LocalPeerDiscoveryClient.messagePort,
        );
        _discovery = discovery;
        AppLogController.instance.record('MESSAGE_RX', 'Message discovery responding on UDP ${LocalPeerDiscoveryClient.messagePort} at ${address.address}');

        final connection = await server.accept(
          timeout: const Duration(seconds: 60),
        );
        _connection = connection;
        await discovery.close();
        _discovery = null;

        final frame = await connection
            .readFrame()
            .timeout(const Duration(seconds: 60));
        if (frame != null && frame.type == ProtocolMessageType.textMessage) {
          final message = TextMessagePayload.decode(frame.payload).text;
          final senderAddress = connection.remoteAddress.address;
          // Keep the delivery order explicit and covered by pure-Dart tests:
          // persist first, acknowledge second, then hand off to the UI and OS notification.
          await BackgroundMessageDelivery(
            persist: () => _saveIncomingMessage(message, senderAddress),
            acknowledge: () => connection.sendFrame(ProtocolFrame(
              ProtocolMessageType.accept,
              const [],
            )),
            notifyMain: (messageId) {
              FlutterForegroundTask.sendDataToMain({
                'action': 'incoming_message_saved',
                'messageId': messageId,
              });
            },
            showNotification: (messageId) =>
                _showIncomingMessage(message, senderAddress, messageId),
          ).deliver();
        }
      } catch (error, stackTrace) {
        AppLogController.instance.record('MESSAGE_RX', 'Receiver loop failed: $error', level: AppLogLevel.error);
        AppLogController.instance.record('MESSAGE_RX', 'Receiver stack: $stackTrace', level: AppLogLevel.warning);
        // A timeout, rejected connection, or Wi-Fi transition starts a fresh
        // short-lived invitation. The service remains available in the LAN.
        if (!_stopping) {
          await Future<void>.delayed(const Duration(milliseconds: 700));
        }
      } finally {
        final connection = _connection;
        _connection = null;
        if (connection != null && !connection.isClosed) {
          await connection.close();
        }
        final discovery = _discovery;
        _discovery = null;
        if (discovery != null && !discovery.isClosed) {
          await discovery.close();
        }
        final server = _server;
        _server = null;
        if (server != null && !server.isClosed) {
          await server.close();
        }
      }
    }
  }

  Future<String> _saveIncomingMessage(String message, String senderAddress) async {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final stored = await FlutterForegroundTask.getData<String>(
      key: _pendingMessagesKey,
    );
    final pending = <Map<String, dynamic>>[];
    if (stored != null && stored.isNotEmpty) {
      try {
        final decoded = jsonDecode(stored);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map) {
              pending.add(Map<String, dynamic>.from(item));
            }
          }
        }
      } on FormatException {
        // Replace invalid old data with a clean pending-message list.
      }
    }
    pending.add({
      'id': id,
      'message': message,
      'sender': senderAddress,
      'receivedAt': DateTime.now().toIso8601String(),
    });
    if (pending.length > 10) {
      pending.removeRange(0, pending.length - 10);
    }
    await FlutterForegroundTask.saveData(
      key: _pendingMessagesKey,
      value: jsonEncode(pending),
    );
    return id;
  }

  Future<void> _showIncomingMessage(
    String message,
    String senderAddress,
    String messageId,
  ) async {
    if (!_notificationReady) await _initializeNotifications();
    final id = DateTime.now().millisecondsSinceEpoch.remainder(0x7fffffff);
    await _notifications.show(
      id: id,
      title: 'Local WiFi Drop · پیام جدید',
      body: message.length > 180 ? '${message.substring(0, 177)}…' : message,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          'local_wifi_drop_incoming_messages',
          'پیام‌های دریافتی',
          channelDescription: 'اعلان پیام‌های جدید Local WiFi Drop',
          importance: Importance.max,
          priority: Priority.high,
          category: AndroidNotificationCategory.message,
          visibility: NotificationVisibility.private,
          playSound: true,
          enableVibration: true,
          autoCancel: true,
          subText: 'از $senderAddress',
        ),
      ),
      payload: 'incoming_message:$messageId',
    );
  }

  Future<InternetAddress?> _findWifiAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      final candidates = <({int priority, InternetAddress address})>[];
      for (final networkInterface in interfaces) {
        final name = networkInterface.name.toLowerCase();
        final priority = name.contains('wlan') || name.contains('wifi') ? 0 : 1;
        for (final address in networkInterface.addresses) {
          if (_isPrivateIpv4(address)) {
            candidates.add((priority: priority, address: address));
          }
        }
      }
      candidates.sort((a, b) => a.priority.compareTo(b.priority));
      return candidates.isEmpty ? null : candidates.first.address;
    } on Object {
      return null;
    }
  }

  bool _isPrivateIpv4(InternetAddress address) {
    final bytes = address.rawAddress;
    if (bytes.length != 4) return false;
    final first = bytes[0];
    final second = bytes[1];
    return first == 10 ||
        (first == 172 && second >= 16 && second <= 31) ||
        (first == 192 && second == 168);
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.sendDataToMain({
      'action': 'open_pending_messages',
    });
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  void onReceiveData(Object data) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _stopping = true;
    AppLogController.instance.record('MESSAGE_RX', 'Background receiver task stopping');
    final connection = _connection;
    _connection = null;
    if (connection != null && !connection.isClosed) {
      await connection.close();
    }
    final discovery = _discovery;
    _discovery = null;
    if (discovery != null && !discovery.isClosed) {
      await discovery.close();
    }
    final server = _server;
    _server = null;
    if (server != null && !server.isClosed) {
      await server.close();
    }
  }
}
