import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:open_filex/open_filex.dart';
import 'src/pairing_invite.dart';
import 'src/chat_transcript.dart';
import 'src/chat_store.dart';
import 'src/local_message_client.dart';
import 'src/background_message_service.dart';
import 'src/transfer_alert_controller.dart';
import 'src/transfer_history_panel.dart';
import 'src/pairing_session_authenticator.dart';
import 'src/receiver_invitation.dart';
import 'src/tcp_transfer_server.dart';
import 'src/tcp_frame_connection.dart';
import 'src/tcp_transfer_client.dart';
import 'src/transfer_alert.dart';
import 'src/tcp_transfer_session.dart';
import 'src/transfer_cancellation.dart';
import 'src/transfer_manifest.dart';
import 'src/local_peer_discovery.dart';
import 'src/send_header.dart';
import 'src/app_log_controller.dart';
import 'src/public_storage_service.dart';

const String _pendingIncomingMessagesKey = 'pending_incoming_messages';
bool _backgroundServiceStarting = false;

Future<void> _ensureBackgroundMessageServiceStarted() async {
  if (!Platform.isAndroid || _backgroundServiceStarting) return;
  _backgroundServiceStarting = true;
  try {
    var permission = await FlutterForegroundTask.checkNotificationPermission();
    if (permission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
      permission = await FlutterForegroundTask.checkNotificationPermission();
    }
    if (permission != NotificationPermission.granted) {
      AppLogController.instance.record('MESSAGE', 'Background message service not started: notification permission denied', level: AppLogLevel.warning);
      return;
    }
    if (await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.startService(
      serviceId: 4201,
      notificationTitle: 'Local WiFi Drop',
      notificationText: 'آماده دریافت پیام از شبکه وای‌فای',
      notificationInitialRoute: '/',
      callback: startBackgroundMessageTask,
      serviceTypes: const [ForegroundServiceTypes.remoteMessaging],
    );
  } catch (error) {
    AppLogController.instance.record('MESSAGE_RX', 'Could not start Android foreground message service: $error', level: AppLogLevel.error);
  } finally {
    _backgroundServiceStarting = false;
  }
}


void main() {
  AppLogController.instance.record('APP', 'Application process started', level: AppLogLevel.success);
  if (Platform.isAndroid) FlutterForegroundTask.initCommunicationPort();
  runApp(const LocalWifiDropApp());
}

class LocalWifiDropApp extends StatefulWidget {
  const LocalWifiDropApp({this.messagePeerDiscovery, super.key});

  final Future<List<DiscoveredMessagePeer>> Function()? messagePeerDiscovery;

  @override
  State<LocalWifiDropApp> createState() => _LocalWifiDropAppState();
}

class _LocalWifiDropAppState extends State<LocalWifiDropApp> with WidgetsBindingObserver {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final TransferAlertController _alerts = TransferAlertController();
  final FlutterLocalNotificationsPlugin _incomingNotifications =
      FlutterLocalNotificationsPlugin();
  bool _showingPendingMessages = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isAndroid) {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'local_wifi_drop_service',
          channelName: 'Local WiFi Drop service',
          channelDescription: 'Keeps local message reception available in the background.',
          channelImportance: NotificationChannelImportance.MIN,
          priority: NotificationPriority.MIN,
          onlyAlertOnce: true,
        ),
        iosNotificationOptions: const IOSNotificationOptions(
          showNotification: false,
          playSound: false,
        ),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.repeat(60000),
          autoRunOnBoot: false,
          autoRunOnMyPackageReplaced: false,
          allowWakeLock: true,
          allowWifiLock: true,
        ),
      );
      FlutterForegroundTask.addTaskDataCallback(_onBackgroundTaskData);
      unawaited(AppLogController.instance.restore());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_initializeAppMessaging());
    });
  }

  Future<void> _initializeAppMessaging() async {
    if (!Platform.isAndroid) return;
    try {
      await _incomingNotifications.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('ic_notification'),
        ),
        onDidReceiveNotificationResponse: (_) {
          unawaited(_showPendingIncomingMessages());
        },
      );
      await _ensureBackgroundMessageServiceStarted();
      await _showPendingIncomingMessages();
    } catch (_) {
      // Message reception can continue even if notification tap setup fails.
      unawaited(_ensureBackgroundMessageServiceStarted());
    }
  }

  void _onBackgroundTaskData(Object data) {
    if (data is Map && (data['action'] == 'open_pending_messages' ||
        data['action'] == 'incoming_message_saved')) {
      unawaited(_showPendingIncomingMessages());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    AppLogController.instance.record('LIFECYCLE', 'App state changed: ${state.name}');
    if (state == AppLifecycleState.detached) {
      ChatStore.instance.clear();
      return;
    }
    if (!Platform.isAndroid) return;
    if (state == AppLifecycleState.paused) {
      // Keep the same receiver running while the UI is backgrounded.
      unawaited(_ensureBackgroundMessageServiceStarted());
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_ensureBackgroundMessageServiceStarted());
      unawaited(_showPendingIncomingMessages());
    }
  }

  Future<void> _showPendingIncomingMessages() async {
    if (!Platform.isAndroid ||
        _showingPendingMessages ||
        !mounted ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    _showingPendingMessages = true;
    try {
      final stored = await FlutterForegroundTask.getData<String>(
        key: _pendingIncomingMessagesKey,
      );
      if (stored == null || stored.isEmpty) return;
      final decoded = jsonDecode(stored);
      if (decoded is! List) return;
      final messages = decoded
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList(growable: false);
      for (final item in messages) {
        final message = item['message'] is String ? item['message'] as String : '';
        final id = item['id'] is String ? item['id'] as String : null;
        if (message.isNotEmpty) {
          final sender = item['sender'] is String ? item['sender'] as String : null;
          final incoming = ChatStore.instance.addIncoming(
            message,
            senderAddress: sender,
            deliveryId: id,
          );
          if (incoming != null) {
            AppLogController.instance.record(
              'MESSAGE',
              'Incoming message presented from ${sender ?? 'unknown peer'}',
              level: AppLogLevel.success,
            );
          }
        }
        if (id != null) await _removePendingIncomingMessage(id);
      }
    } catch (_) {
      // Keep unread messages stored if the UI cannot process them yet.
    } finally {
      _showingPendingMessages = false;
    }
  }

  Future<void> _removePendingIncomingMessage(String id) async {
    final stored = await FlutterForegroundTask.getData<String>(
      key: _pendingIncomingMessagesKey,
    );
    if (stored == null || stored.isEmpty) return;
    try {
      final decoded = jsonDecode(stored);
      if (decoded is! List) return;
      final remaining = decoded.where((item) =>
          item is! Map || item['id'] != id).toList(growable: false);
      await FlutterForegroundTask.saveData(
        key: _pendingIncomingMessagesKey,
        value: jsonEncode(remaining),
      );
    } on FormatException {
      // Leave malformed storage untouched for diagnosis.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isAndroid) {
      FlutterForegroundTask.removeTaskDataCallback(_onBackgroundTaskData);
    }
    _alerts.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'Local WiFi Drop',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2563EB)),
        useMaterial3: true,
      ),
      home: SendScreen(alerts: _alerts, messagePeerDiscovery: widget.messagePeerDiscovery),
    );
  }
}

class SendScreen extends StatefulWidget {
  const SendScreen({required this.alerts, this.messagePeerDiscovery, super.key});

  /// Shared app history; pass [alerts.onAlert] to the sender session callback.
  final TransferAlertController alerts;
  final Future<List<DiscoveredMessagePeer>> Function()? messagePeerDiscovery;

  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen> with WidgetsBindingObserver {
  final GlobalKey _bottomSendButtonAnchorKey = GlobalKey(debugLabel: 'bottom-send-button-anchor');
  final List<PlatformFile> _selectedFiles = [];
  bool _isPicking = false;
  bool _isSending = false;
  bool _cancelRequested = false;
  bool _sessionStarted = false;
  TransferCancellation? _cancellation;
  final TextEditingController _destinationController = TextEditingController();
  String? _deviceIpAddress;
  bool _isLoadingDeviceIp = true;
  final TextEditingController _messageController = TextEditingController();
  DiscoveredPeer? _selectedPeer;
  String? _manualAddress;
  bool _isDiscovering = false;
  List<String> _discoveredDevices = [];
  final LayerLink _peerPickerLayerLink = LayerLink();
  final GlobalKey _peerPickerFieldKey = GlobalKey();
  OverlayEntry? _peerPickerOverlay;
  int _sentBytes = 0;
  int _totalSendBytes = 0;
  DateTime _lastSendProgressUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastSendLogUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  List<ChatMessage> get _chatMessages => ChatStore.instance.messages;

  ChatMessage _addChatMessage(String text, {required bool isOutgoing, bool isDelivered = false}) {
    if (isOutgoing) return ChatStore.instance.addOutgoing(text, isDelivered: isDelivered);
    return ChatStore.instance.addIncoming(text)!;
  }
  void _removeChatMessage(ChatMessage message) => ChatStore.instance.remove(message.id);
  void _markChatMessageDelivered(ChatMessage message) => ChatStore.instance.markDelivered(message.id);
  void _onChatStoreChanged() {
    final selectedAddress = ChatStore.instance.selectedPeerAddress;
    if (selectedAddress != null && selectedAddress != _manualAddress) {
      _selectedPeer = null;
      _manualAddress = selectedAddress;
      _destinationController.text = selectedAddress;
    } else if (selectedAddress == null && _manualAddress != null) {
      _manualAddress = null;
      _selectedPeer = null;
      _destinationController.text = _deviceIpAddress ?? '';
    }
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ChatStore.instance.addListener(_onChatStoreChanged);
    final selectedAddress = ChatStore.instance.selectedPeerAddress;
    if (selectedAddress != null) {
      _manualAddress = selectedAddress;
      _destinationController.text = selectedAddress;
    }
    _loadDeviceIpAddress();
  }

  Future<void> _loadDeviceIpAddress() async {
    String? deviceIp;
    try {
      final address = await _preferredPrivateIpv4Address();
      deviceIp = address.address;
    } catch (_) {
      // The device IP may be unavailable while Wi-Fi is disconnected or starting.
    }
    if (!mounted) return;
    setState(() {
      _deviceIpAddress = deviceIp;
      _isLoadingDeviceIp = false;
      if (_selectedPeer == null && _manualAddress == null && ChatStore.instance.selectedPeerAddress == null) {
        _destinationController.text = _deviceIpAddress ?? '';
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    AppLogController.instance.record('LIFECYCLE', 'Send screen state: ${state.name}');
    if (state != AppLifecycleState.resumed && _isSending) {
      _cancelSending();
    }
    if (state == AppLifecycleState.resumed) {
      _restoreWindowAfterResume();
    }
  }

  void _restoreWindowAfterResume() {
    // Android can return from another app with the old IME-resized viewport.
    // Dismiss any stale text-input connection and rebuild after window insets settle.
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
    FocusManager.instance.primaryFocus?.unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ChatStore.instance.removeListener(_onChatStoreChanged);
    _cancelRequested = true;
    _cancellation?.cancel();
    _closePeerDropdown();
    _destinationController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  int get _knownTotalBytes => _selectedFiles.fold<int>(
        0,
        (total, file) => total + (file.lengthSync() ?? 0),
      );

  Future<void> _pickFiles() async {
    AppLogController.instance.record('UI', 'Choose File button pressed');
    if (_isPicking) return;
    setState(() => _isPicking = true);
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.any,
      );
      if (!mounted) return;
      AppLogController.instance.record(
        'FILE_PICKER',
        files.isEmpty
            ? 'File picker closed without selecting files'
            : 'File picker returned ${files.length} file(s)',
      );
      if (files.isNotEmpty) {
        setState(() {
          final newFiles = files.where((file) {
            return !_selectedFiles.any(
              (existing) =>
                  existing.name == file.name &&
                  existing.lengthSync() == file.lengthSync(),
            );
          }).toList(growable: false);
          _selectedFiles.insertAll(0, newFiles);
        });
      }
    } catch (error) {
      AppLogController.instance.record(
        'FILE_PICKER',
        'File picker failed: $error',
        level: AppLogLevel.error,
      );
      if (mounted) {
        _showMessage('Could not open the file picker: $error');
      }
    } finally {
      if (mounted) setState(() => _isPicking = false);
    }
  }

  Future<void> _pasteMessage() async {
    AppLogController.instance.record('UI', 'Paste message button pressed');
    final clipboard = await Clipboard.getData('text/plain');
    if (!mounted) return;
    final text = clipboard?.text;
    if (text == null || text.isEmpty) {
      AppLogController.instance.record('UI', 'Paste message failed: clipboard is empty', level: AppLogLevel.warning);
      _showMessage('Clipboard is empty.');
      return;
    }
    AppLogController.instance.record('UI', 'Clipboard text pasted into Send composer');
    _messageController.text = text;
    _messageController.selection = TextSelection.collapsed(
      offset: _messageController.text.length,
    );
    if (mounted) setState(() {});
  }

  Future<void> _sendTextMessage() async {
    AppLogController.instance.record('MESSAGE', 'Send button pressed', level: AppLogLevel.info);
    if (_isSending) return;
    final text = _messageController.text;
    if (text.trim().isEmpty) { _showMessage('Write a message first.'); return; }
    if (Platform.isAndroid && await FlutterForegroundTask.checkNotificationPermission() != NotificationPermission.granted) {
      _showMessage('Notification permission is required for messaging.');
      return;
    }
    final destination = ChatStore.instance.selectedPeerAddress ?? _selectedPeer?.address ?? _manualAddress ?? _destinationController.text.trim();
    if (destination.isEmpty) { _showMessage('Select an online receiver first.'); return; }
    setState(() { _isSending = true; _cancelRequested = false; });
    final outgoingMessage = _addChatMessage(text, isOutgoing: true);
    try {
      await LocalMessageClient().sendToAddress(destination, text);
      if (!mounted) return;
      if (_messageController.text == text) _messageController.clear();
      _markChatMessageDelivered(outgoingMessage);
      AppLogController.instance.record('MESSAGE', 'Message stored by receiver and delivery confirmed', level: AppLogLevel.success);
      _showMessage('Message sent.');
    } catch (error) {
      AppLogController.instance.record('MESSAGE', 'Message delivery failed. Reason: $error', level: AppLogLevel.error);
      _removeChatMessage(outgoingMessage);
      widget.alerts.add(TransferAlert(fileName: 'Message to $destination — failed', status: TransferAlertStatus.failed));
      if (mounted) _showMessage('Message could not be delivered: $error');
    } finally { if (mounted) setState(() => _isSending = false); }
  }

  Future<void> _sendSelectedDestination() async {
    if (_selectedPeer == null && _manualAddress == null) return;
    await _beginSend(() async {
      final selected = _selectedPeer;
      if (selected != null) return selected.invitation;

      final address = InternetAddress(_manualAddress!);
      final peers = await const LocalPeerDiscoveryClient().discover(
        targetAddress: address,
        purpose: 'file',
      );
      for (final peer in peers) {
        if (peer.address == address.address) return peer.invitation;
      }
      throw SocketException('No Local WiFi Drop receiver responded at ${address.address}.');
    });
  }

  Future<void> _beginSend(
    Future<PairingInvite> Function() resolveInvitation,
  ) async {
    AppLogController.instance.record('SEND', 'File send operation started for: ${_selectedFiles.map((file) => file.name).join(', ')}');
    if (_isSending) return;
    setState(() {
      _isSending = true;
      _cancelRequested = false;
      _sessionStarted = false;
      _sentBytes = 0;
      _totalSendBytes = 0;
      _lastSendProgressUpdate = DateTime.fromMillisecondsSinceEpoch(0);
    });
    try {
      final invitation = await resolveInvitation();
      if (_cancelRequested) return;
      await _transferFiles(invitation);
    } catch (error) {
      AppLogController.instance.record('SEND', 'File send setup failed. Reason: $error', level: AppLogLevel.error);
      if (mounted && !_cancelRequested) {
        _showMessage('Could not send files: $error');
      }
    } finally {
      if (_cancelRequested && !_sessionStarted) {
        for (final file in _selectedFiles) {
          widget.alerts.add(TransferAlert(
            fileName: file.name,
            status: TransferAlertStatus.cancelled,
          ));
        }
      }
      _cancellation = null;
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _transferFiles(PairingInvite invitation) async {
    final sourceFiles = <File>[];
    final entries = <TransferFileEntry>[];
    for (final selected in _selectedFiles) {
      final path = selected.path;
      if (path == null) {
        throw FileSystemException(
          'The selected file has no readable local path.',
          selected.name,
        );
      }
      final file = File(path);
      if (!await file.exists()) {
        throw FileSystemException('The selected file is no longer available.', path);
      }
      final size = await file.length();
      sourceFiles.add(file);
      entries.add(TransferFileEntry(name: selected.name, size: size));
    }
    if (_cancelRequested) return;

    final random = Random.secure();
    final manifest = TransferManifest(
      batchId: List<int>.generate(16, (_) => random.nextInt(256)),
      files: entries,
    );
    final connection = await TcpTransferClient.connect(invitation: invitation);
    if (_cancelRequested) {
      await connection.close();
      return;
    }

    final cancellation = TransferCancellation();
    _cancellation = cancellation;
    _sessionStarted = true;
    final outcome = await const TcpTransferSession().sendBatch(
      connection: connection,
      manifest: manifest,
      files: sourceFiles,
      cancellation: cancellation,
      onAlert: widget.alerts.onSendAlert,
      onProgress: (sent, total) {
        final now = DateTime.now();
        if (!mounted ||
            (sent != total &&
                now.difference(_lastSendProgressUpdate) <
                    const Duration(milliseconds: 100))) {
          return;
        }
        _lastSendProgressUpdate = now;
        if (sent == total || now.difference(_lastSendLogUpdate) >= const Duration(seconds: 1)) {
          _lastSendLogUpdate = now;
          AppLogController.instance.record('SEND_PROGRESS', 'Transferred $sent / $total bytes');
        }
        setState(() {
          _sentBytes = sent;
          _totalSendBytes = total;
        });
      },
    );
    if (!mounted) return;
    _showMessage(switch (outcome) {
      SenderSessionOutcome.completed => 'Files sent.',
      SenderSessionOutcome.rejected => 'The receiver rejected this batch.',
      SenderSessionOutcome.cancelled => 'Transfer cancelled.',
    });
  }

  static const MethodChannel _networkChannel =
      MethodChannel('local_wifi_drop/network');

  Future<List<String>> _scanNetworkDeviceIps() async {
    final devices = <String>{};
    try {
      final discoverPeers = widget.messagePeerDiscovery;
      final peers = discoverPeers != null
          ? await discoverPeers()
          : await const LocalPeerDiscoveryClient().discoverMessagePeers(
              timeout: const Duration(milliseconds: 1400),
            );
      devices.addAll(peers.map((peer) => peer.address));
      AppLogController.instance.record(
        'NETWORK',
        'UDP app discovery found ${peers.length} Local WiFi Drop receiver(s)',
      );
    } catch (error) {
      AppLogController.instance.record(
        'NETWORK',
        'UDP app discovery failed: $error',
        level: AppLogLevel.warning,
      );
    }

    // Also scan the current Wi-Fi subnet. The native scan finds responding
    // LAN hosts even when UDP broadcast discovery is filtered by the router.
    try {
      final scanned = await _networkChannel.invokeMethod<List<dynamic>>(
        'scanWifiDevices',
      );
      for (final value in scanned ?? const <dynamic>[]) {
        if (value is! String) continue;
        final address = InternetAddress.tryParse(value);
        if (address != null &&
            address.type == InternetAddressType.IPv4 &&
            _isSupportedPrivateIpv4(address)) {
          devices.add(address.address);
        }
      }
      AppLogController.instance.record(
        'NETWORK',
        'Native Wi-Fi subnet scan returned ${scanned?.length ?? 0} responding host(s)',
      );
    } catch (error) {
      AppLogController.instance.record(
        'NETWORK',
        'Native Wi-Fi subnet scan unavailable: $error',
        level: AppLogLevel.warning,
      );
    }

    final result = devices.toList()..sort();
    AppLogController.instance.record(
      'NETWORK',
      'Combined LAN scan returned ${result.length} device IP(s): ${result.join(', ')}',
    );
    return result;
  }

  Future<void> _openPeerPicker() async {
    AppLogController.instance.record('NETWORK', 'Device scan requested from destination field');
    if (_isDiscovering || _isSending) return;
    _closePeerDropdown();
    AppLogController.instance.record('NETWORK', 'IP discovery started: UDP discovery plus Wi-Fi subnet scan');
    setState(() => _isDiscovering = true);
    List<String> devices = [];
    try {
      devices = await _scanNetworkDeviceIps();
    } catch (error) {
      AppLogController.instance.record('NETWORK', 'Wi-Fi device scan failed: $error', level: AppLogLevel.error);
      if (mounted) _showMessage('Wi-Fi device scan failed: $error');
    } finally {
      if (mounted) setState(() => _isDiscovering = false);
    }
    if (!mounted) return;
    _discoveredDevices = devices;
    _showPeerDropdown();
  }

  Future<void> _refreshPeerDropdown() async {
    AppLogController.instance.record('NETWORK', 'Refresh devices button pressed');
    if (_isDiscovering || _isSending) return;
    AppLogController.instance.record('NETWORK', 'IP discovery refresh started: UDP discovery plus Wi-Fi subnet scan');
    setState(() => _isDiscovering = true);
    _peerPickerOverlay?.markNeedsBuild();
    List<String> devices = [];
    try {
      devices = await _scanNetworkDeviceIps();
    } catch (error) {
      AppLogController.instance.record('NETWORK', 'Wi-Fi device scan failed: $error', level: AppLogLevel.error);
      if (mounted) _showMessage('Wi-Fi device scan failed: $error');
    } finally {
      if (mounted) {
        setState(() {
          _isDiscovering = false;
          _discoveredDevices = devices;
        });
        _peerPickerOverlay?.markNeedsBuild();
      }
    }
  }

  void _showPeerDropdown() {
    final fieldContext = _peerPickerFieldKey.currentContext;
    final fieldBox = fieldContext?.findRenderObject();
    final overlay = Overlay.of(context);
    if (fieldBox is! RenderBox || !fieldBox.hasSize) return;

    final fieldTop = fieldBox.localToGlobal(Offset.zero).dy;
    final fieldHeight = fieldBox.size.height;
    final availableHeight =
        MediaQuery.of(context).size.height - fieldTop - fieldHeight - 20;
    final menuHeight = availableHeight.clamp(100.0, 360.0);

    _peerPickerOverlay = OverlayEntry(
      builder: (overlayContext) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _closePeerDropdown,
              child: const SizedBox.expand(),
            ),
          ),
          CompositedTransformFollower(
            link: _peerPickerLayerLink,
            showWhenUnlinked: false,
            offset: Offset(0, fieldHeight + 6),
            child: Material(
              color: Colors.transparent,
              child: SizedBox(
                width: fieldBox.size.width,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: menuHeight),
                  child: Material(
                    key: const ValueKey('send-peer-dropdown'),
                    elevation: 12,
                    color: const Color(0xFFF8FBF8),
                    borderRadius: BorderRadius.circular(12),
                    clipBehavior: Clip.antiAlias,
                    child: ListView(
                      padding: EdgeInsets.zero,
                      shrinkWrap: true,
                      children: [
                        ListTile(
                          dense: true,
                          title: Row(
                            children: [
                              const Expanded(
                                child: Text(
                                  'Devices found on this network',
                                  style: TextStyle(fontWeight: FontWeight.w700),
                                ),
                              ),
                              IconButton(
                                key: const ValueKey('refresh-network-devices'),
                                tooltip: 'Refresh devices',
                                onPressed: _isDiscovering ? null : _refreshPeerDropdown,
                                constraints: const BoxConstraints.tightFor(
                                  width: 32,
                                  height: 32,
                                ),
                                padding: EdgeInsets.zero,
                                visualDensity: VisualDensity.compact,
                                icon: _isDiscovering
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      )
                                    : const Icon(Icons.refresh, size: 19),
                              ),
                            ],
                          ),
                          subtitle: Text(
                            _discoveredDevices.isEmpty
                                ? 'No responding devices found.'
                                : '${_discoveredDevices.length} responding device(s)',
                          ),
                        ),
                        for (final address in _discoveredDevices)
                          ListTile(
                            dense: true,
                            leading: const Icon(
                              Icons.devices,
                              color: Color(0xFF159447),
                            ),
                            title: Text(
                              address,
                              style: const TextStyle(
                                color: Color(0xFF16452A),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: const Text('Device on this Wi-Fi'),
                            onTap: () {
                              _closePeerDropdown();
                              AppLogController.instance.record('NETWORK', 'Destination device selected: $address');
                              ChatStore.instance.selectPeer(address);
                              setState(() {
                                _selectedPeer = null;
                                _manualAddress = address;
                                _destinationController.text = address;
                              });
                            },
                          ),
                        const Divider(height: 1),
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.edit, color: Color(0xFF159447)),
                          title: const Text('Enter IP manually'),
                          onTap: () {
                            _closePeerDropdown();
                            _enterManualIp();
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    overlay.insert(_peerPickerOverlay!);
  }

  void _closePeerDropdown() {
    _peerPickerOverlay?.remove();
    _peerPickerOverlay = null;
  }

  Future<void> _enterManualIp() async {
    AppLogController.instance.record('UI', 'Enter IP manually action opened');
    if (_isSending) return;
    final controller = TextEditingController(text: _manualAddress ?? '');
    final entered = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Enter device IP'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: '192.168.1.25',
            labelText: 'Private IPv4 address',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Use IP'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || entered == null) return;

    final address = InternetAddress.tryParse(entered.trim());
    if (address == null || !_isSupportedPrivateIpv4(address)) {
      _showMessage('Enter a valid private IPv4 address.');
      return;
    }
    final peers = await const LocalPeerDiscoveryClient().discoverMessagePeers(
      targetAddress: address,
      timeout: const Duration(milliseconds: 1400),
    );
    if (!mounted) return;
    if (!peers.any((peer) => peer.address == address.address)) {
      _showMessage('This IP has no online Local WiFi Drop message receiver.');
      return;
    }
    AppLogController.instance.record('NETWORK', 'Verified online message receiver selected: ${address.address}');
    ChatStore.instance.selectPeer(address.address);
    setState(() {
      _manualAddress = address.address;
      _selectedPeer = null;
      _destinationController.text = address.address;
    });
  }
  void _cancelSending() {
    AppLogController.instance.record('SEND', 'Cancel sending action requested', level: AppLogLevel.warning);
    if (!_isSending) return;
    _cancelRequested = true;
    _cancellation?.cancel();
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final progress = _totalSendBytes > 0
        ? (_sentBytes / _totalSendBytes).clamp(0.0, 1.0).toDouble()
        : 0.0;
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          const Positioned.fill(child: MatrixRainBackground()),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                children: [
                  SendHeader(
                    logPanelBottomKey: _bottomSendButtonAnchorKey,
                    alertController: widget.alerts,
                    alertsPanel: TransferHistoryPanel(controller: widget.alerts),
                    onSendTap: () {},
                    onReceiveTap: () {
                      AppLogController.instance.record('UI', 'Receive tab pressed');
                      Navigator.of(context).push(
                      PageRouteBuilder<void>(
                        opaque: true,
                        transitionDuration: Duration.zero,
                        reverseTransitionDuration: Duration.zero,
                        pageBuilder: (_, __, ___) =>
                            ReceiveScreen(alerts: widget.alerts),
                      ),
                    );
                    },
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ListView(
                      padding: EdgeInsets.zero,
                      children: [
                        _unencryptedWarning(),
                        const SizedBox(height: 10),
                        _sendCard(
                          child: CompositedTransformTarget(
                            key: _peerPickerFieldKey,
                            link: _peerPickerLayerLink,
                            child: InkWell(
                            key: const ValueKey('send-destination-picker'),
                            borderRadius: BorderRadius.circular(10),
                            onTap: _openPeerPicker,
                            child: InputDecorator(
                              decoration: InputDecoration(
                                hintText: 'Select a device on this Wi-Fi',
                                prefixIcon: const Icon(Icons.wifi, color: Color(0xFF159447)),
                                suffixIcon: _isDiscovering
                                    ? const Padding(
                                        padding: EdgeInsets.all(12),
                                        child: SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(strokeWidth: 2),
                                        ),
                                      )
                                    : const Icon(Icons.arrow_drop_down),
                                filled: true,
                                fillColor: const Color(0xFFF3F7F4),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(11),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                              child: Text(
                                _destinationController.text.isNotEmpty
                                    ? _destinationController.text
                                    : (_isLoadingDeviceIp ? 'Detecting this device…' : 'Device IP unavailable'),
                                style: const TextStyle(color: Color(0xFF16452A)),
                              ),
                            ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        _sendCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              OutlinedButton.icon(
                                onPressed: _isPicking || _isSending ? null : _pickFiles,
                                icon: _isPicking
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      )
                                    : const Icon(Icons.add),
                                label: Text(_isPicking ? 'Opening files…' : 'Choose File'),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: const Color(0xFF087A35),
                                  side: const BorderSide(color: Color(0xFF20C65A)),
                                  padding: const EdgeInsets.symmetric(vertical: 13),
                                ),
                              ),
                              if (_selectedFiles.isNotEmpty) ...[
                                const SizedBox(height: 10),
                                SizedBox(
                                  height: 168,
                                  child: ListView.builder(
                                    key: const ValueKey('selected-files-scroll'),
                                    reverse: true,
                                    padding: EdgeInsets.zero,
                                    itemCount: _selectedFiles.length,
                                    itemBuilder: (context, visibleIndex) {
                                      final index = _selectedFiles.length - 1 - visibleIndex;
                                      final file = _selectedFiles[index];
                                      return Padding(
                                        padding: const EdgeInsets.only(bottom: 6),
                                        child: SizedBox(
                                          height: 50,
                                          child: Row(
                                            children: [
                                              const Icon(Icons.insert_drive_file, color: Color(0xFF159447)),
                                              const SizedBox(width: 9),
                                              Expanded(
                                                child: Column(
                                                  mainAxisAlignment: MainAxisAlignment.center,
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      file.name,
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                        color: Color(0xFF16452A),
                                                        fontWeight: FontWeight.w600,
                                                      ),
                                                    ),
                                                    Text(
                                                      _formatBytes(file.lengthSync() ?? 0),
                                                      style: const TextStyle(color: Color(0xFF718078), fontSize: 12),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              IconButton(
                                                tooltip: 'Remove file',
                                                onPressed: _isSending
                                                    ? null
                                                    : () {
                                                        AppLogController.instance.record(
                                                          'FILE',
                                                          'Removed file from Send selection: ${file.name}',
                                                        );
                                                        setState(() => _selectedFiles.removeAt(index));
                                                      },
                                                icon: const Icon(Icons.close, color: Color(0xFF718078)),
                                              ),
                                            ],
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: Text(
                                    '${_selectedFiles.length} file(s) · ${_formatBytes(_knownTotalBytes)}',
                                    style: const TextStyle(color: Color(0xFF718078), fontSize: 12),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        _sendCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Row(
                                children: [
                                  Icon(Icons.message_outlined, color: Color(0xFF159447)),
                                  SizedBox(width: 9),
                                  Text('Message', style: TextStyle(
                                    color: Color(0xFF16452A),
                                    fontWeight: FontWeight.w700,
                                  )),
                                ],
                              ),
                              if (_chatMessages.isNotEmpty) ...[
                                ChatTranscript(
                                  key: const ValueKey('send-chat-transcript'),
                                  messages: _chatMessages,
                                ),
                                const SizedBox(height: 8),
                              ],
                              TextField(
                                key: const ValueKey('send-message-field'),
                                controller: _messageController,
                                style: const TextStyle(color: Colors.black),
                                onChanged: (_) => setState(() {}),
                                minLines: 3,
                                maxLines: 3,
                                decoration: InputDecoration(
                                  hintText: 'Write message',
                                  filled: true,
                                  fillColor: const Color(0xFFF3F7F4),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(11),
                                    borderSide: BorderSide.none,
                                  ),
                                  contentPadding: const EdgeInsets.all(12),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Expanded(
                                    child: SizedBox(
                                      height: 34,
                                      child: FilledButton(
                                        key: const ValueKey('send-text-message'),
                                        onPressed: _isSending ||
                                                _messageController.text.trim().isEmpty ||
                                                (ChatStore.instance.selectedPeerAddress == null && _selectedPeer == null && _manualAddress == null)
                                            ? null
                                            : _sendTextMessage,
                                        style: FilledButton.styleFrom(
                                          backgroundColor: const Color(0xFF159447),
                                          foregroundColor: Colors.white,
                                          disabledBackgroundColor: const Color(0xFF159447),
                                          disabledForegroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(horizontal: 10),
                                          minimumSize: const Size(0, 34),
                                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                          visualDensity: VisualDensity.compact,
                                        ),
                                        child: const Text('Send'),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: SizedBox(
                                      height: 34,
                                      child: FilledButton(
                                        key: const ValueKey('paste-text-message'),
                                        onPressed: _isSending ? null : _pasteMessage,
                                        style: FilledButton.styleFrom(
                                          backgroundColor: const Color(0xFF159447),
                                          foregroundColor: Colors.white,
                                          disabledBackgroundColor: const Color(0xFF159447),
                                          disabledForegroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(horizontal: 10),
                                          minimumSize: const Size(0, 34),
                                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                          visualDensity: VisualDensity.compact,
                                        ),
                                        child: const Text('Paste'),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        _sendCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Expanded(
                                    child: Text(
                                      'Sending Progress',
                                      style: TextStyle(
                                        color: Color(0xFF16452A),
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    '${(progress * 100).round()}%',
                                    style: const TextStyle(
                                      color: Color(0xFF159447),
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: LinearProgressIndicator(
                                  value: _totalSendBytes > 0 ? progress : 0,
                                  minHeight: 9,
                                  backgroundColor: const Color(0xFFE3EAE5),
                                  color: const Color(0xFF20C65A),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _totalSendBytes > 0
                                    ? '${_formatBytes(_sentBytes)} / ${_formatBytes(_totalSendBytes)}'
                                    : 'Ready to send',
                                style: const TextStyle(color: Color(0xFF718078), fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!keyboardVisible) ...[
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            key: _bottomSendButtonAnchorKey,
                            child: FilledButton.icon(
                            key: const ValueKey('bottom-send-button'),
                            onPressed: _isSending
                                ? _cancelSending
                                : (_selectedFiles.isNotEmpty &&
                                        (_selectedPeer != null || _manualAddress != null)
                                    ? _sendSelectedDestination
                                    : null),
                            icon: Icon(_isSending ? Icons.close : Icons.send),
                            label: Text(_isSending ? 'Cancel' : 'Send'),
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF20C65A),
                              foregroundColor: const Color(0xFF05230F),
                              disabledBackgroundColor: const Color(0xFF20C65A),
                              disabledForegroundColor: const Color(0xFF05230F),
                              padding: const EdgeInsets.symmetric(vertical: 15),
                            ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _unencryptedWarning() => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: const Color(0xFFFFF3CD), borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFFE7C66A))),
        child: const Text(
          'This app has no encryption to keep it lightweight. Do not send important or sensitive messages or files.',
          style: TextStyle(color: Color(0xFF6B4F00), fontSize: 12, fontWeight: FontWeight.w600),
        ),
      );

  Widget _sendCard({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(color: Color(0x33000000), blurRadius: 8, offset: Offset(0, 3)),
        ],
      ),
      child: child,
    );
  }
}

class ReceiveScreen extends StatefulWidget {
  const ReceiveScreen({required this.alerts, super.key});

  final TransferAlertController alerts;

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> with WidgetsBindingObserver {
  TcpTransferServer? _server;
  LocalPeerDiscoveryResponder? _discoveryResponder;
  TransferCancellation? _cancellation;
  String? _destinationPath;
  bool _starting = false;
  String _senderAddress = 'From';
  bool _cancelRequested = false;
  bool _receivingTransfer = false;
  bool _approvalDialogOpen = false;
  int _receiveResetGeneration = 0;
  DateTime _lastReceiveProgressUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastReceiveLogUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  int _receivedBytes = 0;
  int _totalBytes = 0;
  List<File> _receivedFiles = [];
  bool _receivedFilesExpanded = false;
  File? _selectedReceivedFile;
  final TextEditingController _receivedMessageController = TextEditingController();
  List<ChatMessage> get _chatMessages => ChatStore.instance.messages;
  bool _isSendingReply = false;

  ChatMessage _addChatMessage(String text, {required bool isOutgoing, bool isDelivered = false}) {
    if (isOutgoing) return ChatStore.instance.addOutgoing(text, isDelivered: isDelivered);
    return ChatStore.instance.addIncoming(text)!;
  }
  void _removeChatMessage(ChatMessage message) => ChatStore.instance.remove(message.id);
  void _markChatMessageDelivered(ChatMessage message) => ChatStore.instance.markDelivered(message.id);
  void _onChatStoreChanged() { if (mounted) setState(() {}); }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ChatStore.instance.addListener(_onChatStoreChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_startReceiving());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _starting) {
      unawaited(_cancelReceiving());
    }
    if (state == AppLifecycleState.resumed) {
      _restoreWindowAfterResume();
      unawaited(_restartReceiverAfterResume());
    }
  }

  Future<void> _restartReceiverAfterResume() async {
    while (mounted && _starting && _cancelRequested) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (mounted && !_starting) unawaited(_startReceiving());
  }

  void _restoreWindowAfterResume() {
    // Prevent a stale keyboard inset from leaving the page at half height.
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
    FocusManager.instance.primaryFocus?.unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ChatStore.instance.removeListener(_onChatStoreChanged);
    _cancelRequested = true;
    _cancellation?.cancel();
    final server = _server;
    if (server != null && !server.isClosed) unawaited(server.close());
    final discovery = _discoveryResponder;
    if (discovery != null && !discovery.isClosed) unawaited(discovery.close());
    _receivedMessageController.dispose();
    super.dispose();
  }

  Future<void> _startReceiving() async {
    _receiveResetGeneration++;
    AppLogController.instance.record(
      'RECEIVE',
      'Receive page listener startup requested',
    );
    if (_starting) return;
    setState(() {
      _starting = true;
      _senderAddress = 'From';
      _cancelRequested = false;
      _receivedBytes = 0;
      _totalBytes = 0;
      _receivedFiles = [];
      _receivedFilesExpanded = false;
      _selectedReceivedFile = null;
      _receivedMessageController.clear();
      _lastReceiveProgressUpdate = DateTime.fromMillisecondsSinceEpoch(0);
    });

    try {
      while (mounted && !_cancelRequested) {
        TcpTransferServer? server;
        TcpFrameConnection? acceptedConnection;
        var listenerReady = false;
        try {
          final address = await _preferredPrivateIpv4Address();
          if (!mounted || _cancelRequested) break;
          AppLogController.instance.record(
            'NETWORK',
            'Receiver binding to local address ${address.address}',
          );

          server = await TcpTransferServer.bind(address: address);
          _server = server;
          final invitation = ReceiverInvitation.create(
            host: address.address,
            port: server.port,
          );
          final authenticator = PairingSessionAuthenticator(
            credentials: invitation.credentials,
            expiresAt: invitation.expiresAt,
          );
          try {
            _discoveryResponder = await LocalPeerDiscoveryResponder.start(
              invitation: invitation.uri,
              acceptedPurpose: 'file',
            );
          } catch (error) {
            AppLogController.instance.record(
              'FILE_RX',
              'Could not start UDP discovery responder on port 39475: $error',
              level: AppLogLevel.error,
            );
            rethrow;
          }
          listenerReady = true;
          AppLogController.instance.record(
            'FILE_RX',
            'File discovery responding on UDP 39475 at ${address.address}; TCP receiver port ${server.port}',
            level: AppLogLevel.success,
          );
          if (!mounted || _cancelRequested) break;

          final cancellation = TransferCancellation();
          _cancellation = cancellation;
          final timeout = invitation.expiresAt.difference(DateTime.now().toUtc());
          final connection = await server.acceptAuthenticated(
            authenticator: authenticator,
            timeout: timeout,
          );
          acceptedConnection = connection;
          _receivingTransfer = true;
          await _discoveryResponder?.close();
          _discoveryResponder = null;
          if (!mounted || _cancelRequested) {
            await connection.close();
            break;
          }

          setState(() {
            _senderAddress = connection.remoteAddress.address;
            _receivedBytes = 0;
            _totalBytes = 0;
            _lastReceiveProgressUpdate = DateTime.fromMillisecondsSinceEpoch(0);
          });

          final firstFrame = await connection
              .readFrame()
              .timeout(const Duration(seconds: 60));
          if (firstFrame == null) {
            throw const FormatException(
              'Sender disconnected before sending content.',
            );
          }

          var destinationPath = _destinationPath;
          if (Platform.isAndroid) {
            destinationPath =
                await PublicStorageService.instance.getStagingDirectory();
          } else if (destinationPath == null ||
              !await Directory(destinationPath).exists()) {
            destinationPath = await FilePicker.getDirectoryPath();
          }
          if (!mounted || _cancelRequested || destinationPath == null) {
            await connection.close();
            break;
          }
          _destinationPath = destinationPath;

          final result = await const TcpTransferSession().receiveBatch(
            connection: connection,
            initialFrame: firstFrame,
            destinationDirectory: Directory(destinationPath),
            approve: _confirmIncoming,
            cancellation: cancellation,
            onProgress: (received, total) {
              final now = DateTime.now();
              if (!mounted ||
                  (received != total &&
                      now.difference(_lastReceiveProgressUpdate) <
                          const Duration(milliseconds: 100))) {
                return;
              }
              _lastReceiveProgressUpdate = now;
              if (received == total ||
                  now.difference(_lastReceiveLogUpdate) >=
                      const Duration(seconds: 1)) {
                _lastReceiveLogUpdate = now;
                AppLogController.instance.record(
                  'RECEIVE_PROGRESS',
                  'Received $received / $total bytes',
                );
              }
              setState(() {
                _receivedBytes = received;
                _totalBytes = total;
              });
            },
            onAlert: widget.alerts.onReceiveAlert,
            finalizeFiles: (files) async {
              if (!Platform.isAndroid) return;
              for (final file in files) {
                await PublicStorageService.instance.publishReceivedFile(file);
                AppLogController.instance.record(
                  'STORAGE',
                  'Published received file to Documents/Local Wi-Fi Drop/Received: ${file.uri.pathSegments.last}',
                  level: AppLogLevel.success,
                );
              }
            },
          );
          if (!mounted) break;
          setState(() {
            _receivedFiles = List<File>.unmodifiable(result.files);
          });
          if (result.outcome == ReceiverSessionOutcome.completed) {
            final resetGeneration = ++_receiveResetGeneration;
            Future<void>.delayed(const Duration(seconds: 10), () {
              if (!mounted ||
                  _receivingTransfer ||
                  _receiveResetGeneration != resetGeneration) {
                return;
              }
              setState(() {
                _senderAddress = 'From';
                _receivedBytes = 0;
                _totalBytes = 0;
                _receivedFiles = [];
                _receivedFilesExpanded = false;
                _selectedReceivedFile = null;
                _destinationPath = null;
              });
            });
          }
        } on TimeoutException {
          if (_cancelRequested || !mounted) break;
          AppLogController.instance.record(
            'FILE_RX',
            'File invitation expired without a connection; refreshing the receiver listener',
            level: AppLogLevel.info,
          );
        } catch (error) {
          if (_cancelRequested || !mounted) break;
          AppLogController.instance.record(
            'RECEIVE',
            'Receive operation failed. Reason: $error',
            level: AppLogLevel.error,
          );
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Could not receive files: $error')),
            );
          }
          if (!listenerReady) break;
          await Future<void>.delayed(const Duration(seconds: 1));
        } finally {
          if (acceptedConnection != null && !acceptedConnection.isClosed) {
            await acceptedConnection.close();
          }
          if (server != null && !server.isClosed) {
            await server.close();
          }
          if (identical(_server, server)) _server = null;
          _receivingTransfer = false;
          await _discoveryResponder?.close();
          _discoveryResponder = null;
          _cancellation = null;
        }

        if (mounted && !_cancelRequested) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
    } finally {
      _receivingTransfer = false;
      _server = null;
      await _discoveryResponder?.close();
      _discoveryResponder = null;
      _cancellation = null;
      if (mounted) {
        setState(() {
          _starting = false;
        });
      }
    }
  }

  Future<void> _sendReplyMessage() async {
    AppLogController.instance.record('MESSAGE', 'Receive-screen Send button pressed');
    final destination = ChatStore.instance.selectedPeerAddress ?? ChatStore.instance.lastIncomingSenderAddress;
    final text = _receivedMessageController.text;
    if (destination == null || destination.isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No message sender is available to reply to.')));
      return;
    }
    if (text.trim().isEmpty || _isSendingReply) return;
    if (Platform.isAndroid && await FlutterForegroundTask.checkNotificationPermission() != NotificationPermission.granted) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Notification permission is required for messaging.')));
      return;
    }
    setState(() => _isSendingReply = true);
    final outgoingMessage = _addChatMessage(text, isOutgoing: true);
    try {
      await LocalMessageClient().sendToAddress(destination, text);
      if (mounted) {
        if (_receivedMessageController.text == text) _receivedMessageController.clear();
        _markChatMessageDelivered(outgoingMessage);
        AppLogController.instance.record('MESSAGE', 'Receive-screen reply delivery confirmed by receiver', level: AppLogLevel.success);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Message sent.')));
      }
    } catch (error) {
      AppLogController.instance.record('MESSAGE', 'Receive-screen reply delivery failed: $error', level: AppLogLevel.error);
      _removeChatMessage(outgoingMessage);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not send message: $error')));
    } finally { if (mounted) setState(() => _isSendingReply = false); }
  }

  Future<void> _pasteReplyMessage() async {
    AppLogController.instance.record('UI', 'Paste reply button pressed');
    final clipboard = await Clipboard.getData('text/plain');
    if (!mounted) return;
    final text = clipboard?.text;
    if (text == null || text.isEmpty) {
      AppLogController.instance.record('UI', 'Paste reply failed: clipboard is empty', level: AppLogLevel.warning);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Clipboard is empty.')),
      );
      return;
    }
    AppLogController.instance.record('UI', 'Clipboard text pasted into Receive composer');
    setState(() {
      _receivedMessageController.text = text;
      _receivedMessageController.selection = TextSelection.collapsed(
        offset: text.length,
      );
    });
  }

  Future<bool> _confirmIncoming(TransferManifest manifest) async {
    AppLogController.instance.record('RECEIVE', 'Incoming batch approval requested: ${manifest.files.map((file) => file.name).join(', ')}');
    if (!mounted) return false;
    _approvalDialogOpen = true;
    try {
      final accepted = await showDialog<bool>(
        context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Incoming files'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${manifest.files.length} file(s) · ${_formatBytes(manifest.totalBytes)}'),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final file in manifest.files)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(_formatBytes(file.size)),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text('Save to: ${Platform.isAndroid ? 'Documents/Local Wi-Fi Drop/Received' : _destinationPath}'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Reject'),
          ),
          TextButton(
            onPressed: () {
              _cancellation?.cancel();
              Navigator.of(dialogContext).pop(false);
            },
            child: const Text('Cancel transfer'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Accept files'),
          ),
        ],
      ),
      );
      final approved = accepted ?? false;
      AppLogController.instance.record('RECEIVE', approved ? 'Incoming file batch accepted' : 'Incoming file batch rejected/cancelled', level: approved ? AppLogLevel.success : AppLogLevel.warning);
      return approved;
    } finally {
      _approvalDialogOpen = false;
    }
  }

  Future<void> _cancelReceiving() async {
    AppLogController.instance.record('RECEIVE', 'Cancel receiving action requested', level: AppLogLevel.warning);
    if (!_starting) return;
    _cancelRequested = true;
    _cancellation?.cancel();
    if (_approvalDialogOpen && mounted) {
      unawaited(Navigator.of(context, rootNavigator: true).maybePop());
    }
    await _discoveryResponder?.close();
    _discoveryResponder = null;
    final server = _server;
    if (server != null && !server.isClosed) {
      await server.close();
    }

  }

  Future<void> _openReceivedFile() async {
    AppLogController.instance.record('UI', 'Open received file location action pressed');
    final file = _selectedReceivedFile ?? (_receivedFiles.isEmpty ? null : _receivedFiles.last);
    if (file == null) return;
    AppLogController.instance.record('FILE', 'Showing received file location: ${file.path}');
    if (Platform.isAndroid) {
      try {
        await PublicStorageService.instance.openReceivedFolder();
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not open the received files folder: $error')),
          );
        }
      }
    } else {
      await OpenFilex.open(file.path);
    }
  }

  Future<void> _deleteSelectedReceivedFile() async {
    final file = _selectedReceivedFile;
    if (file == null) return;
    try {
      if (!mounted) return;
      setState(() {
        _receivedFiles = _receivedFiles.where((item) => item.path != file.path).toList();
        _selectedReceivedFile = null;
        if (_receivedFiles.isEmpty) _receivedFilesExpanded = false;
      });
      AppLogController.instance.record(
        'FILE',
        'Removed received file from app list; stored file was kept: ${file.path}',
        level: AppLogLevel.success,
      );
    } catch (error) {
      AppLogController.instance.record(
        'FILE',
        'Could not delete received file: ${file.path}. Reason: $error',
        level: AppLogLevel.error,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not delete file: $error')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = _totalBytes > 0
        ? (_receivedBytes / _totalBytes).clamp(0.0, 1.0).toDouble()
        : 0.0;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          const Positioned.fill(child: MatrixRainBackground()),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
              child: Column(
                children: [
                  SendHeader(
                    isReceive: true,
                    alertController: widget.alerts,
                    onSendTap: () {
                      AppLogController.instance.record('UI', 'Send tab pressed');
                      Navigator.of(context).push(
                      PageRouteBuilder<void>(
                        opaque: true,
                        transitionDuration: Duration.zero,
                        reverseTransitionDuration: Duration.zero,
                        pageBuilder: (_, __, ___) =>
                            SendScreen(alerts: widget.alerts),
                      ),
                    );
                    },
                    alertsPanel: TransferHistoryPanel(controller: widget.alerts),
                    onReceiveTap: () {},
                  ),
                  const SizedBox(height: 14),
                  Expanded(
                    child: ListView(
                      padding: EdgeInsets.zero,
                      children: [
                        _unencryptedWarning(),
                        const SizedBox(height: 10),
                        _receiveCard(
                          child: SizedBox(
                            height: 42,
                            child: InkWell(
                              key: const ValueKey('receive-source-selector'),
                              borderRadius: BorderRadius.circular(9),
                              onTap: _starting ? _cancelReceiving : _startReceiving,
                              child: Center(
                                child: Text(
                                  _senderAddress,
                                  key: const ValueKey('receive-sender-address'),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Color(0xFF16452A),
                                    fontWeight: FontWeight.w700,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        _receiveCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Row(
                                children: [
                                  Icon(Icons.insert_drive_file_outlined, color: Color(0xFF159447)),
                                  SizedBox(width: 10),
                                  Text('Received Files', style: TextStyle(fontWeight: FontWeight.w700)),
                                ],
                              ),
                              const SizedBox(height: 8),
                              AnimatedSize(
                                duration: const Duration(milliseconds: 220),
                                curve: Curves.easeInOut,
                                alignment: Alignment.topCenter,
                                child: Column(
                                  key: const ValueKey('received-files-list'),
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    Material(
                                      color: const Color(0xFFF3F6F4),
                                      borderRadius: BorderRadius.circular(10),
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(10),
                                        onTap: _receivedFiles.length > 1
                                            ? () {
                                                final expanded = !_receivedFilesExpanded;
                                                AppLogController.instance.record(
                                                  'UI',
                                                  expanded
                                                      ? 'Received file list expanded'
                                                      : 'Received file list collapsed',
                                                );
                                                setState(() => _receivedFilesExpanded = expanded);
                                              }
                                            : null,
                                        child: SizedBox(
                                          height: 56,
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(horizontal: 10),
                                            child: Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    (_selectedReceivedFile ??
                                                            (_receivedFiles.isEmpty ? null : _receivedFiles.last))
                                                        ?.uri.pathSegments.last ??
                                                        '',
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                    style: const TextStyle(color: Color(0xFF16452A)),
                                                  ),
                                                ),
                                                if (_receivedFiles.length > 1) ...[
                                                  const SizedBox(width: 8),
                                                  Icon(
                                                    _receivedFilesExpanded
                                                        ? Icons.keyboard_arrow_up
                                                        : Icons.keyboard_arrow_down,
                                                    color: const Color(0xFF087A35),
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    if (_receivedFilesExpanded && _receivedFiles.length > 1)
                                      Container(
                                        margin: const EdgeInsets.only(top: 4),
                                        constraints: const BoxConstraints(maxHeight: 180),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFF3F6F4),
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        child: ListView.builder(
                                          shrinkWrap: true,
                                          padding: EdgeInsets.zero,
                                          itemCount: _receivedFiles.length,
                                          itemBuilder: (context, index) {
                                            final file = _receivedFiles[
                                                _receivedFiles.length - 1 - index];
                                            final isSelected =
                                                _selectedReceivedFile?.path == file.path;
                                            return ListTile(
                                              dense: true,
                                              visualDensity: VisualDensity.compact,
                                              selected: isSelected,
                                              selectedTileColor: const Color(0xFFB9EBC9),
                                              onTap: () {
                                                AppLogController.instance.record(
                                                  'FILE',
                                                  'Selected received file: ${file.uri.pathSegments.last}',
                                                );
                                                setState(() => _selectedReceivedFile = file);
                                              },
                                              leading: Icon(
                                                isSelected
                                                    ? Icons.check_circle
                                                    : Icons.insert_drive_file_outlined,
                                                color: const Color(0xFF159447),
                                                size: 20,
                                              ),
                                              title: Text(
                                                file.uri.pathSegments.last,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: isSelected
                                                      ? const Color(0xFF087A35)
                                                      : const Color(0xFF16452A),
                                                  fontSize: 13,
                                                  fontWeight: isSelected
                                                      ? FontWeight.w700
                                                      : FontWeight.normal,
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: _receivedFiles.isEmpty ? null : _openReceivedFile,
                                      icon: const Icon(Icons.folder_open),
                                      label: const Text('Open'),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: const Color(0xFF087A35),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: _selectedReceivedFile == null ? null : _deleteSelectedReceivedFile,
                                      icon: const Icon(Icons.delete_outline),
                                      label: const Text('Delete'),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: const Color(0xFFB42318),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        _receiveCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Row(
                                children: [
                                  Icon(Icons.message_outlined, color: Color(0xFF159447)),
                                  SizedBox(width: 9),
                                  Text('Message', style: TextStyle(
                                    color: Color(0xFF16452A),
                                    fontWeight: FontWeight.w700,
                                  )),
                                ],
                              ),
                              if (_chatMessages.isNotEmpty) ...[
                                ChatTranscript(
                                  key: const ValueKey('receive-chat-transcript'),
                                  messages: _chatMessages,
                                ),
                                const SizedBox(height: 8),
                              ],
                              TextField(
                                key: const ValueKey('received-message-field'),
                                controller: _receivedMessageController,
                                style: const TextStyle(color: Colors.black),
                                onChanged: (_) => setState(() {}),
                                minLines: 3,
                                maxLines: 3,
                                decoration: const InputDecoration(
                                  hintText: 'Write message',
                                  filled: true,
                                  fillColor: Color(0xFFF3F7F4),
                                  border: OutlineInputBorder(
                                    borderSide: BorderSide.none,
                                    borderRadius: BorderRadius.all(Radius.circular(11)),
                                  ),
                                  contentPadding: EdgeInsets.all(12),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Expanded(
                                    child: SizedBox(
                                      height: 34,
                                      child: FilledButton(
                                        key: const ValueKey('receive-send-text-message'),
                                        onPressed: _isSendingReply ||
                                                ChatStore.instance.selectedPeerAddress == null &&
                                                ChatStore.instance.lastIncomingSenderAddress == null ||
                                                _receivedMessageController.text.trim().isEmpty
                                            ? null
                                            : _sendReplyMessage,
                                        style: FilledButton.styleFrom(
                                          backgroundColor: const Color(0xFF159447),
                                          foregroundColor: Colors.white,
                                          disabledBackgroundColor: const Color(0xFF159447),
                                          disabledForegroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(horizontal: 10),
                                          minimumSize: const Size(0, 34),
                                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                          visualDensity: VisualDensity.compact,
                                        ),
                                        child: const Text('Send'),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: SizedBox(
                                      height: 34,
                                      child: FilledButton(
                                        key: const ValueKey('receive-paste-text-message'),
                                        onPressed: _isSendingReply ? null : _pasteReplyMessage,
                                        style: FilledButton.styleFrom(
                                          backgroundColor: const Color(0xFF159447),
                                          foregroundColor: Colors.white,
                                          disabledBackgroundColor: const Color(0xFF159447),
                                          disabledForegroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(horizontal: 10),
                                          minimumSize: const Size(0, 34),
                                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                          visualDensity: VisualDensity.compact,
                                        ),
                                        child: const Text('Paste'),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        _receiveCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.downloading, color: Color(0xFF159447)),
                                  const SizedBox(width: 9),
                                  const Expanded(
                                    child: Text('Receiving Progress', style: TextStyle(fontWeight: FontWeight.w700)),
                                  ),
                                  Text('${(progress * 100).round()}%'),
                                ],
                              ),
                              const SizedBox(height: 12),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: LinearProgressIndicator(
                                  value: _totalBytes > 0 ? progress : 0,
                                  minHeight: 9,
                                  backgroundColor: const Color(0xFFE3EAE5),
                                  color: const Color(0xFF20C65A),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    _totalBytes > 0
                                        ? '${_formatBytes(_receivedBytes)} / ${_formatBytes(_totalBytes)}'
                                        : 'Transferred: -- / --',
                                    style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
                                  ),
                                  const Text(
                                    'Elapsed: --:--',
                                    style: TextStyle(color: Color(0xFF64748B), fontSize: 12),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                      ],
                    ),
                  ),

                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _unencryptedWarning() => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: const Color(0xFFFFF3CD), borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFFE7C66A))),
        child: const Text(
          'This app has no encryption to keep it lightweight. Do not send important or sensitive messages or files.',
          style: TextStyle(color: Color(0xFF6B4F00), fontSize: 12, fontWeight: FontWeight.w600),
        ),
      );

  Widget _receiveCard({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(color: Color(0x33000000), blurRadius: 8, offset: Offset(0, 3)),
        ],
      ),
      child: child,
    );
  }
}

class MatrixRainBackground extends StatefulWidget {
  const MatrixRainBackground({super.key});

  @override
  State<MatrixRainBackground> createState() => _MatrixRainBackgroundState();
}

class _MatrixRainBackgroundState extends State<MatrixRainBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 18),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => CustomPaint(
        painter: _MatrixRainPainter(progress: _controller.value),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _MatrixRainPainter extends CustomPainter {
  const _MatrixRainPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final background = Paint()..color = Colors.black;
    canvas.drawRect(Offset.zero & size, background);

    final random = Random(41);
    const glyphs = '0123456789';
    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    // Narrower column spacing and longer streams create a denser Matrix effect
    // consistently on both Send and Receive screens.
    for (var column = 0; column < (size.width / 12).ceil(); column++) {
      final x = column * 12.0;
      final start = random.nextDouble() * size.height;
      final speed = 0.55 + random.nextDouble() * 0.9;
      final length = 8 + random.nextInt(20);
      for (var row = 0; row < length; row++) {
        final y = (start + progress * size.height * speed + row * 15) %
                (size.height + 30) -
            15;
        final glyph = glyphs[random.nextInt(glyphs.length)];
        textPainter.text = TextSpan(
          text: glyph,
          style: TextStyle(
            color: Color.fromRGBO(30, 220, 90, row == 0 ? 0.62 : 0.22),
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        );
        textPainter.layout();
        textPainter.paint(canvas, Offset(x, y));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _MatrixRainPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

Future<InternetAddress> _preferredPrivateIpv4Address() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
    includeLinkLocal: false,
  );
  final candidates = <({String interfaceName, InternetAddress address})>[];
  for (final interface in interfaces) {
    for (final address in interface.addresses) {
      if (_isSupportedPrivateIpv4(address)) {
        candidates.add((interfaceName: interface.name.toLowerCase(), address: address));
      }
    }
  }
  if (candidates.isEmpty) {
    throw const SocketException('No private IPv4 address is available on this device.');
  }
  candidates.sort((left, right) {
    final leftWifi = left.interfaceName.contains('wlan') ||
        left.interfaceName.contains('wifi');
    final rightWifi = right.interfaceName.contains('wlan') ||
        right.interfaceName.contains('wifi');
    if (leftWifi == rightWifi) return 0;
    return leftWifi ? -1 : 1;
  });
  return candidates.first.address;
}

bool _isSupportedPrivateIpv4(InternetAddress address) {
  if (address.type != InternetAddressType.IPv4) return false;
  final bytes = address.rawAddress;
  return bytes[0] == 10 ||
      (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
      (bytes[0] == 192 && bytes[1] == 168);
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}