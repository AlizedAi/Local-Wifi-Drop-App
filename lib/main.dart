import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'src/pairing_invite.dart';
import 'src/chat_transcript.dart';
import 'src/chat_store.dart';
import 'src/local_message_client.dart';
import 'src/active_message_receiver.dart';
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
import 'src/app_language_controller.dart';
import 'src/message_sound.dart';
import 'src/sent_file_selection.dart';
import 'src/public_storage_service.dart';
import 'src/windows_lan_scanner.dart';

void main() {
  AppLogController.instance.record('APP', 'Application process started', level: AppLogLevel.success);
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
  final ActiveMessageReceiver _messageReceiver = ActiveMessageReceiver();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(AppLanguageController.instance.load());
    AppLanguageController.instance.language.addListener(_onLanguageChanged);
    if (Platform.isAndroid) {
      unawaited(AppLogController.instance.restore());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_initializeAppMessaging());
    });
  }

  void _onLanguageChanged() { if (mounted) setState(() {}); }

  Future<void> _initializeAppMessaging() async {
    try {
      await _messageReceiver.start();
      AppLogController.instance.record('MESSAGE_RX', 'In-app message listener started', level: AppLogLevel.success);
    } catch (error) {
      AppLogController.instance.record('MESSAGE_RX', 'Could not start message listener: $error', level: AppLogLevel.error);
    }
    if (Platform.isAndroid) {
      try {
        await const MethodChannel('local_wifi_drop/storage').invokeMethod<bool>('requestStorageAccess');
      } catch (error) {
        AppLogController.instance.record('PERMISSION', 'Could not request full storage access: $error', level: AppLogLevel.warning);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    AppLogController.instance.record('LIFECYCLE', 'App state changed: ${state.name}');
    if (state == AppLifecycleState.detached) {
      unawaited(_messageReceiver.stop());
      ChatStore.instance.clear();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppLanguageController.instance.language.removeListener(_onLanguageChanged);
    unawaited(_messageReceiver.stop());
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
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2563EB),
          brightness: Brightness.dark,
          surface: Colors.black,
        ),
        scaffoldBackgroundColor: Colors.black,
        canvasColor: Colors.black,
        dialogTheme: const DialogTheme(
          backgroundColor: Colors.black,
          surfaceTintColor: Colors.transparent,
        ),
        popupMenuTheme: const PopupMenuThemeData(
          color: Colors.black,
          surfaceTintColor: Colors.transparent,
        ),
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
  int _headerRevision = 0;
  GlobalKey _alertButtonKey = GlobalKey(debugLabel: 'send-alert-button');
  void _onLanguageChanged() { if (mounted) setState(() {}); }
  final List<PlatformFile> _selectedFiles = [];
  final Map<String, int> _selectedFileSizes = {};
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
  Set<String> _onlineAppDevices = {};
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
    AppLanguageController.instance.language.addListener(_onLanguageChanged);
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
    if (state == AppLifecycleState.detached && _isSending) {
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
      if (mounted) {
        setState(() {
          _headerRevision++;
          _alertButtonKey = GlobalKey(debugLabel: 'send-alert-button-$_headerRevision');
        });
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppLanguageController.instance.language.removeListener(_onLanguageChanged);
    ChatStore.instance.removeListener(_onChatStoreChanged);
    _cancelRequested = true;
    _cancellation?.cancel();
    _closePeerDropdown();
    _destinationController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  String _fileKey(PlatformFile file) =>
      file.path ?? file.identifier ?? file.name;

  int _fileSizeFor(PlatformFile file) =>
      _selectedFileSizes[_fileKey(file)] ?? file.size;

  int get _knownTotalBytes => _selectedFiles.fold<int>(
        0,
        (total, file) => total + _fileSizeFor(file),
      );

  Future<void> _pickFiles() async {
    AppLogController.instance.record('UI', 'Choose File button pressed');
    if (_isPicking) return;
    setState(() => _isPicking = true);
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.any,
      );
      final files = picked?.files ?? const <PlatformFile>[];
      if (!mounted) return;
      AppLogController.instance.record(
        'FILE_PICKER',
        files.isEmpty
            ? 'File picker closed without selecting files'
            : 'File picker returned ${files.length} file(s)',
      );
      if (files.isNotEmpty) {
        for (final file in files) {
          var actualSize = file.size;
          if (actualSize <= 0 && file.path != null) {
            try {
              actualSize = await File(file.path!).length();
            } catch (error) {
              AppLogController.instance.record(
                'FILE_PICKER',
                'Could not read file size for ${file.name}: $error',
                level: AppLogLevel.warning,
              );
            }
          }
          _selectedFileSizes[_fileKey(file)] = actualSize;
        }
        if (!mounted) return;
        setState(() {
          // File identity is its readable path or picker identifier, not its
          // display name and size: separate folders may contain same-named files.
          final knownKeys = _selectedFiles.map(_fileKey).toSet();
          final newFiles = <PlatformFile>[];
          for (final file in files) {
            final key = _fileKey(file);
            if (knownKeys.add(key)) newFiles.add(file);
          }
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
        _showMessage('${_tr('Could not open the file picker: ')}$error');
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
      _showMessage(_tr('Clipboard is empty.'));
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
    if (text.trim().isEmpty) { _showMessage(_tr('Write a message first.')); return; }
    final destination = ChatStore.instance.selectedPeerAddress ?? _selectedPeer?.address ?? _manualAddress ?? _destinationController.text.trim();
    if (destination.isEmpty) { _showMessage(_tr('Select an online receiver first.')); return; }
    setState(() { _isSending = true; _cancelRequested = false; });
    final outgoingMessage = _addChatMessage(text, isOutgoing: true);
    try {
      await LocalMessageClient().sendToAddress(destination, text);
      if (!mounted) return;
      if (_messageController.text == text) _messageController.clear();
      _markChatMessageDelivered(outgoingMessage);
      AppLogController.instance.record('MESSAGE', 'Message stored by receiver and delivery confirmed', level: AppLogLevel.success);
      _showMessage(_tr('Message sent.'));
      await MessageSound.playSent();
    } catch (error) {
      AppLogController.instance.record('MESSAGE', 'Message delivery failed. Reason: $error', level: AppLogLevel.error);
      _removeChatMessage(outgoingMessage);
      widget.alerts.add(TransferAlert(fileName: 'Message to $destination — failed', status: TransferAlertStatus.failed));
      if (mounted) _showMessage('${_tr('Message could not be delivered: ')}$error');
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
        _showMessage('${_tr('Could not send files: ')}$error');
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
    final selectedBatch = List<PlatformFile>.of(_selectedFiles);
    final sourceFiles = <File>[];
    final entries = <TransferFileEntry>[];
    for (final selected in selectedBatch) {
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
    if (outcome == SenderSessionOutcome.completed) {
      setState(() => removeSuccessfullySentFiles(_selectedFiles, selectedBatch));
      AppLogController.instance.record(
        'SEND',
        'Removed ${selectedBatch.length} successfully sent file(s) from the Send selection',
        level: AppLogLevel.success,
      );
    }
    _showMessage(_tr(switch (outcome) {
      SenderSessionOutcome.completed => 'Files sent.',
      SenderSessionOutcome.rejected => 'The receiver rejected this batch.',
      SenderSessionOutcome.cancelled => 'Transfer cancelled.',
    }));
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
      _onlineAppDevices = peers.map((peer) => peer.address).toSet();
      devices.addAll(_onlineAppDevices);
      AppLogController.instance.record(
        'NETWORK',
        'UDP app discovery found ${peers.length} Local WiFi Drop receiver(s)',
      );
    } catch (error) {
      _onlineAppDevices = {};
      AppLogController.instance.record(
        'NETWORK',
        'UDP app discovery failed: $error',
        level: AppLogLevel.warning,
      );
    }

    // Android has a native best-effort LAN inventory scan. Other desktop
    // platforms use the portable UDP app-peer discovery above; they must not
    // invoke an Android-only MethodChannel.
    if (Platform.isAndroid) {
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
    } else if (Platform.isWindows) {
      try {
        final scanned = await const WindowsLanScanner().scan();
        devices.addAll(scanned);
        AppLogController.instance.record(
          'NETWORK',
          'Windows IPv4 subnet scan returned ${scanned.length} responding or ARP-discovered host(s)',
          level: AppLogLevel.success,
        );
      } catch (error) {
        AppLogController.instance.record(
          'NETWORK',
          'Windows LAN inventory scan failed: $error',
          level: AppLogLevel.error,
        );
      }
    } else {
      AppLogController.instance.record(
        'NETWORK',
        'Full LAN client inventory is not available on this platform',
        level: AppLogLevel.info,
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
      if (mounted) _showMessage('${_tr('Wi-Fi device scan failed: ')}$error');
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
      if (mounted) _showMessage('${_tr('Wi-Fi device scan failed: ')}$error');
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
                              Expanded(
                                child: Text(
                                  _tr('Devices found on this network'),
                                  style: const TextStyle(fontWeight: FontWeight.w700),
                                ),
                              ),
                              IconButton(
                                key: const ValueKey('refresh-network-devices'),
                                tooltip: _tr('Refresh devices'),
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
                                ? _tr('No responding devices found.')
                                : '${_discoveredDevices.length} ${_tr('responding device(s)')}',
                          ),
                        ),
                        for (final address in _discoveredDevices)
                          ListTile(
                            dense: true,
                            leading: const Icon(
                              Icons.devices,
                              color: Color(0xFF159447),
                            ),
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    address,
                                    style: const TextStyle(
                                      color: Color(0xFF16452A),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                if (_onlineAppDevices.contains(address))
                                  Text(
                                    _tr('Online'),
                                    style: const TextStyle(
                                      color: Color(0xFF20C65A),
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                              ],
                            ),
                            subtitle: Text(_tr('Device on this Wi-Fi')),
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
                          title: Text(_tr('Enter IP manually')),
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
        title: Text(_tr('Enter device IP')),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            hintText: '192.168.1.25',
            labelText: _tr('Private IPv4 address'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(_tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: Text(_tr('Use IP')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || entered == null) return;

    final address = InternetAddress.tryParse(entered.trim());
    if (address == null || !_isSupportedPrivateIpv4(address)) {
      _showMessage(_tr('Enter a valid private IPv4 address.'));
      return;
    }
    final peers = await const LocalPeerDiscoveryClient().discoverMessagePeers(
      targetAddress: address,
      timeout: const Duration(milliseconds: 1400),
    );
    if (!mounted) return;
    if (!peers.any((peer) => peer.address == address.address)) {
      _showMessage(_tr('This IP has no online Local WiFi Drop message receiver.'));
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
          const Positioned.fill(child: ColoredBox(color: Colors.black)),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                children: [
                  SendHeader(
                    key: ValueKey('send-header-$_headerRevision'),
                    alertButtonKey: _alertButtonKey,
                    logPanelBottomKey: _bottomSendButtonAnchorKey,
                    alertController: widget.alerts,
                    alertsPanel: TransferHistoryPanel(controller: widget.alerts),
                    onSendTap: () {},
                    onReceiveTap: () {
                      AppLogController.instance.record('UI', 'Receive tab pressed');
                      Navigator.of(context).pushReplacement(
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
                        _sendCard(
                          backgroundColor: Colors.black,
                          child: CompositedTransformTarget(
                            key: _peerPickerFieldKey,
                            link: _peerPickerLayerLink,
                            child: InkWell(
                            key: const ValueKey('send-destination-picker'),
                            borderRadius: BorderRadius.circular(10),
                            onTap: _openPeerPicker,
                            child: Directionality(
                              textDirection: TextDirection.ltr,
                              child: InputDecorator(
                              decoration: InputDecoration(
                                hintText: _tr('Select a device on this Wi-Fi'),
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
                                    : const Icon(Icons.arrow_drop_down, color: Colors.black),
                                filled: true,
                                fillColor: Colors.white,
                                border: const OutlineInputBorder(
                                  borderSide: BorderSide(color: Colors.black, width: 2),
                                ),
                                enabledBorder: const OutlineInputBorder(
                                  borderSide: BorderSide(color: Colors.black, width: 2),
                                ),
                                focusedBorder: const OutlineInputBorder(
                                  borderSide: BorderSide(color: Colors.black, width: 2),
                                ),
                              ),
                              child: Text(
                                _destinationController.text.isNotEmpty
                                    ? _destinationController.text
                                    : (_isLoadingDeviceIp ? _tr('Detecting this device…') : _tr('Device IP unavailable')),
                                style: const TextStyle(color: Colors.black),
                                textDirection: TextDirection.ltr,
                                maxLines: 1,
                                softWrap: false,
                                overflow: TextOverflow.ellipsis,
                              ),
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
                                label: Text(_tr(_isPicking ? 'Opening files…' : 'Choose File')),
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
                                    padding: EdgeInsets.zero,
                                    itemCount: _selectedFiles.length,
                                    itemBuilder: (context, index) {
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
                                                      _formatBytes(_fileSizeFor(file)),
                                                      style: const TextStyle(color: Color(0xFF718078), fontSize: 12),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              IconButton(
                                                tooltip: _tr('Remove file'),
                                                onPressed: _isSending
                                                    ? null
                                                    : () {
                                                        AppLogController.instance.record(
                                                          'FILE',
                                                          'Removed file from Send selection: ${file.name}',
                                                        );
                                                        setState(() {
                                                          final removed = _selectedFiles.removeAt(index);
                                                          _selectedFileSizes.remove(_fileKey(removed));
                                                        });
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
                                    '${_selectedFiles.length} ${_tr('file(s)')} · ${_formatBytes(_knownTotalBytes)}',
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
                              Row(
                                children: [
                                  const Icon(Icons.message_outlined, color: Color(0xFF159447)),
                                  const SizedBox(width: 9),
                                  Text(_tr('Message'), style: const TextStyle(
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
                                textDirection: AppLanguageController.instance.isPersian ? TextDirection.rtl : TextDirection.ltr,
                                textAlign: AppLanguageController.instance.isPersian ? TextAlign.right : TextAlign.left,
                                onChanged: (_) => setState(() {}),
                                minLines: 3,
                                maxLines: 3,
                                decoration: InputDecoration(
                                  hintText: _tr('Write message'),
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
                              Directionality(
                                textDirection: AppLanguageController.instance.isPersian ? TextDirection.rtl : TextDirection.ltr,
                                child: Row(
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
                                        child: Text(_tr('Send')),
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
                                        child: Text(_tr('Paste')),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
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
                                  Expanded(
                                    child: Text(
                                      _tr('Sending Progress'),
                                      style: const TextStyle(
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
                                    : _tr('Ready to send'),
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
                            label: Text(_tr(_isSending ? 'Cancel' : 'Send')),
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

  Widget _sendCard({required Widget child, Color backgroundColor = Colors.white}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: backgroundColor,
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
  final GlobalKey _alertButtonKey = GlobalKey(debugLabel: 'receive-alert-button');
  void _onLanguageChanged() { if (mounted) setState(() {}); }
  LocalPeerDiscoveryResponder? _discoveryResponder;
  TransferCancellation? _cancellation;
  String? _destinationPath;
  bool _starting = false;
  String _senderAddress = 'From';
  bool _cancelRequested = false;
  bool _receiverActive = false;
  Completer<bool>? _pendingApproval;
  String? _incomingFileName;
  DateTime _lastReceiveProgressUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastReceiveLogUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  int _receivedBytes = 0;
  int _totalBytes = 0;
  static final List<File> _receivedFiles = [];
  static final Map<String, String> _publishedFileUris = {};
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
    AppLanguageController.instance.language.addListener(_onLanguageChanged);
    ChatStore.instance.addListener(_onChatStoreChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_startReceiving());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached && _starting) {
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
    AppLanguageController.instance.language.removeListener(_onLanguageChanged);
    ChatStore.instance.removeListener(_onChatStoreChanged);
    _cancelRequested = true;
    _cancellation?.cancel();
    final pending = _pendingApproval;
    if (pending != null && !pending.isCompleted) pending.complete(false);
    final server = _server;
    if (server != null && !server.isClosed) unawaited(server.close());
    final discovery = _discoveryResponder;
    if (discovery != null && !discovery.isClosed) unawaited(discovery.close());
    _receivedMessageController.dispose();
    super.dispose();
  }

  Future<void> _startReceiving() async {
    AppLogController.instance.record(
      'RECEIVE',
      'Receive page listener startup requested',
    );
    if (_receiverActive || _starting) return;
    setState(() {
      _starting = true;
      _senderAddress = 'From';
      _incomingFileName = null;
      _cancelRequested = false;
      _receivedBytes = 0;
      _totalBytes = 0;
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
          _receiverActive = true;
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
              bindAddress: address,
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
            // ignore: deprecated_member_use
            destinationPath = await FilePicker.platform.getDirectoryPath();
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
                final publishedUri = await PublicStorageService.instance.publishReceivedFile(file);
                _publishedFileUris[file.path] = publishedUri;
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
            for (final file in result.files) {
              _receivedFiles.removeWhere((existing) => existing.path == file.path);
              _receivedFiles.add(file);
            }
            if (_receivedFiles.length > 3) {
              _receivedFiles.removeRange(0, _receivedFiles.length - 3);
            }
            if (result.files.isNotEmpty) {
              _selectedReceivedFile = result.files.last;
            }
            _incomingFileName = null;
          });
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
              SnackBar(content: Text('${_tr('Could not receive files: ')}$error')),
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
          _receiverActive = false;
          await _discoveryResponder?.close();
          _discoveryResponder = null;
          _cancellation = null;
        }

        if (mounted && !_cancelRequested) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
    } finally {
      _receiverActive = false;
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
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_tr('No message sender is available to reply to.'))));
      return;
    }
    if (text.trim().isEmpty || _isSendingReply) return;
    setState(() => _isSendingReply = true);
    final outgoingMessage = _addChatMessage(text, isOutgoing: true);
    try {
      await LocalMessageClient().sendToAddress(destination, text);
      if (mounted) {
        if (_receivedMessageController.text == text) _receivedMessageController.clear();
        _markChatMessageDelivered(outgoingMessage);
        AppLogController.instance.record('MESSAGE', 'Receive-screen reply delivery confirmed by receiver', level: AppLogLevel.success);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_tr('Message sent.'))));
        await MessageSound.playSent();
      }
    } catch (error) {
      AppLogController.instance.record('MESSAGE', 'Receive-screen reply delivery failed: $error', level: AppLogLevel.error);
      _removeChatMessage(outgoingMessage);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${_tr('Could not send message: ')}$error')));
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
        SnackBar(content: Text(_tr('Clipboard is empty.'))),
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
    AppLogController.instance.record(
      'RECEIVE',
      'Incoming batch approval requested: ${manifest.files.map((file) => file.name).join(', ')}',
    );
    if (!mounted) return false;
    final completer = Completer<bool>();
    setState(() {
      _incomingFileName = manifest.files.length == 1
          ? manifest.files.single.name
          : '${manifest.files.first.name} (+${manifest.files.length - 1} more)';
      _pendingApproval = completer;
    });
    try {
      final approved = await completer.future;
      AppLogController.instance.record(
        'RECEIVE',
        approved ? 'Incoming file batch accepted' : 'Incoming file batch rejected',
        level: approved ? AppLogLevel.success : AppLogLevel.warning,
      );
      return approved;
    } finally {
      if (identical(_pendingApproval, completer)) {
        _pendingApproval = null;
        if (mounted) {
          setState(() {
            _incomingFileName = null;
          });
        }
      }
    }
  }

  void _resolveIncomingApproval(bool accepted) {
    final pending = _pendingApproval;
    if (pending == null || pending.isCompleted) return;
    pending.complete(accepted);
  }

  Future<void> _cancelReceiving() async {
    AppLogController.instance.record('RECEIVE', 'Cancel receiving action requested', level: AppLogLevel.warning);
    if (!_starting) return;
    _cancelRequested = true;
    _cancellation?.cancel();
    _resolveIncomingApproval(false);
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
            SnackBar(content: Text('${_tr('Could not open the received files folder: ')}$error')),
          );
        }
      }
    } else {
      await OpenFilex.open(file.path);
    }
  }

  Future<void> _deleteSelectedReceivedFile() async {
    final file = _selectedReceivedFile ?? (_receivedFiles.isEmpty ? null : _receivedFiles.last);
    if (file == null) return;
    try {
      // Android's existing storage adapter is kept unchanged. On Windows,
      // Delete removes only the in-app history entry and preserves the file.
      if (Platform.isAndroid) {
        final publishedUri = _publishedFileUris.remove(file.path);
        await PublicStorageService.instance.deleteReceivedFile(
          file: file,
          publishedUri: publishedUri,
        );
      }
      if (!mounted) return;
      setState(() {
        _receivedFiles.removeWhere((item) => item.path == file.path);
        _selectedReceivedFile = _receivedFiles.isEmpty ? null : _receivedFiles.last;
      });
      AppLogController.instance.record(
        'FILE',
        'Removed received file from the app list: ${file.path}',
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
          SnackBar(content: Text('${_tr('Could not delete file: ')}$error')),
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
          const Positioned.fill(child: ColoredBox(color: Colors.black)),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
              child: Column(
                children: [
                  SendHeader(
                    isReceive: true,
                    alertButtonKey: _alertButtonKey,
                    alertController: widget.alerts,
                    onSendTap: () {
                      AppLogController.instance.record('UI', 'Send tab pressed');
                      Navigator.of(context).pushReplacement(
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
                        _receiveCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                _tr('From'),
                                style: const TextStyle(
                                  color: Color(0xFF16452A),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Container(
                                key: const ValueKey('receive-source-selector'),
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF3F6F4),
                                  border: Border.all(color: const Color(0xFF16452A)),
                                  borderRadius: BorderRadius.circular(9),
                                ),
                                child: Text(
                                  _senderAddress == 'From' ? _tr('Waiting for sender IP') : _senderAddress,
                                  key: const ValueKey('receive-sender-address'),
                                  style: const TextStyle(
                                    color: Color(0xFF16452A),
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                _tr('File Name'),
                                style: const TextStyle(
                                  color: Color(0xFF16452A),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Container(
                                key: const ValueKey('receive-incoming-file-name'),
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF3F6F4),
                                  border: Border.all(color: const Color(0xFF16452A)),
                                  borderRadius: BorderRadius.circular(9),
                                ),
                                child: Text(
                                  _incomingFileName ?? _tr('No incoming file'),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: Color(0xFF16452A)),
                                ),
                              ),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  Expanded(
                                    child: FilledButton(
                                      key: const ValueKey('receive-accept-file'),
                                      onPressed: _pendingApproval == null
                                          ? null
                                          : () => _resolveIncomingApproval(true),
                                      style: FilledButton.styleFrom(
                                        backgroundColor: const Color(0xFF159447),
                                        foregroundColor: Colors.white,
                                      ),
                                      child: Text(_tr('Accept')),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: OutlinedButton(
                                      key: const ValueKey('receive-reject-file'),
                                      onPressed: _pendingApproval == null
                                          ? null
                                          : () => _resolveIncomingApproval(false),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: const Color(0xFFB42318),
                                        side: const BorderSide(color: Color(0xFFB42318)),
                                      ),
                                      child: Text(_tr('Reject')),
                                    ),
                                  ),
                                ],
                              ),
                              const Divider(height: 22),
                              Text(
                                _tr('Received Files · Last 3'),
                                style: const TextStyle(
                                  color: Color(0xFF16452A),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 6),
                              if (_receivedFiles.isEmpty)
                                Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                  child: Text(
                                    _tr('No received files'),
                                    style: const TextStyle(color: Color(0xFF718078)),
                                  ),
                                )
                              else
                                for (final file in _receivedFiles.reversed)
                                  ListTile(
                                    key: ValueKey('received-file-${file.path}'),
                                    dense: true,
                                    visualDensity: VisualDensity.compact,
                                    contentPadding: EdgeInsets.zero,
                                    selected: _selectedReceivedFile?.path == file.path,
                                    selectedTileColor: const Color(0xFFB9EBC9),
                                    onTap: () => setState(() => _selectedReceivedFile = file),
                                    leading: Icon(
                                      _selectedReceivedFile?.path == file.path
                                          ? Icons.check_circle
                                          : Icons.insert_drive_file_outlined,
                                      color: const Color(0xFF159447),
                                      size: 20,
                                    ),
                                    title: Text(
                                      file.uri.pathSegments.last,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Color(0xFF16452A),
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: _receivedFiles.isEmpty ? null : _openReceivedFile,
                                      icon: const Icon(Icons.folder_open),
                                      label: Text(_tr('Open')),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: const Color(0xFF087A35),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: _receivedFiles.isEmpty ? null : _deleteSelectedReceivedFile,
                                      icon: const Icon(Icons.delete_outline),
                                      label: Text(_tr('Delete')),
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
                              Row(
                                children: [
                                  const Icon(Icons.message_outlined, color: Color(0xFF159447)),
                                  const SizedBox(width: 9),
                                  Text(_tr('Message'), style: const TextStyle(
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
                                textDirection: AppLanguageController.instance.isPersian ? TextDirection.rtl : TextDirection.ltr,
                                textAlign: AppLanguageController.instance.isPersian ? TextAlign.right : TextAlign.left,
                                onChanged: (_) => setState(() {}),
                                minLines: 3,
                                maxLines: 3,
                                decoration: InputDecoration(
                                  hintText: _tr('Write message'),
                                  filled: true,
                                  fillColor: const Color(0xFFF3F7F4),
                                  border: const OutlineInputBorder(
                                    borderSide: BorderSide.none,
                                    borderRadius: BorderRadius.all(Radius.circular(11)),
                                  ),
                                  contentPadding: const EdgeInsets.all(12),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Directionality(
                                textDirection: AppLanguageController.instance.isPersian ? TextDirection.rtl : TextDirection.ltr,
                                child: Row(
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
                                        child: Text(_tr('Send')),
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
                                        child: Text(_tr('Paste')),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
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
                                  Expanded(
                                    child: Text(_tr('Receiving Progress'), style: const TextStyle(fontWeight: FontWeight.w700)),
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
                                        : _tr('Transferred: -- / --'),
                                    style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
                                  ),
                                  Text(
                                    _tr('Elapsed: --:--'),
                                    style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
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

String _tr(String value) => AppLanguageController.instance.translate(value);

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
