import 'dart:async';
import 'dart:io';

import 'app_log_controller.dart';
import 'chat_store.dart';
import 'message_sound.dart';
import 'local_peer_discovery.dart';
import 'protocol_frame.dart';
import 'tcp_frame_connection.dart';
import 'tcp_transfer_server.dart';

/// Message listener owned by the app process, with no Android service.
class ActiveMessageReceiver {
  TcpTransferServer? _server;
  LocalPeerDiscoveryResponder? _discovery;
  TcpFrameConnection? _connection;
  Future<void>? _loop;
  bool _stopping = false;
  bool _started = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _stopping = false;
    _loop = _listen();
  }

  Future<void> stop() async {
    if (!_started && _loop == null) return;
    _stopping = true;
    final connection = _connection;
    _connection = null;
    if (connection != null && !connection.isClosed) await connection.close();
    final discovery = _discovery;
    _discovery = null;
    if (discovery != null && !discovery.isClosed) await discovery.close();
    final server = _server;
    _server = null;
    if (server != null && !server.isClosed) await server.close();
    final loop = _loop;
    if (loop != null) await loop;
    _loop = null;
    _started = false;
  }

  Future<void> _listen() async {
    AppLogController.instance.record('MESSAGE_RX', 'In-app message listener starting');
    while (!_stopping) {
      try {
        final address = await _findWifiAddress();
        if (_stopping) break;
        if (address == null) {
          await Future<void>.delayed(const Duration(seconds: 2));
          continue;
        }
        final server = await TcpTransferServer.bind(address: address);
        _server = server;
        if (_stopping) break;
        final discovery = await LocalPeerDiscoveryResponder.start(
          messageHost: address.address,
          messageTcpPort: server.port,
          acceptedPurpose: 'message',
          port: LocalPeerDiscoveryClient.messagePort,
        );
        _discovery = discovery;
        AppLogController.instance.record('MESSAGE_RX', 'In-app message listener ready at ${address.address}:${server.port}', level: AppLogLevel.success);
        final connection = await server.accept(timeout: const Duration(days: 1));
        _connection = connection;
        await discovery.close();
        _discovery = null;
        final frame = await connection.readFrame().timeout(const Duration(seconds: 60));
        if (frame == null) throw const SocketException('Sender disconnected.');
        if (frame.type != ProtocolMessageType.textMessage) {
          await connection.sendFrame(ProtocolFrame(ProtocolMessageType.reject, const []));
          throw const FormatException('Unsupported message frame.');
        }
        final message = TextMessagePayload.decode(frame.payload).text;
        final sender = connection.remoteAddress.address;
        ChatStore.instance.addIncoming(message, senderAddress: sender);
        await connection.sendFrame(ProtocolFrame(ProtocolMessageType.accept, const []));
        await MessageSound.playReceived();
        AppLogController.instance.record('MESSAGE_RX', 'Message received from $sender while app process is active', level: AppLogLevel.success);
      } catch (error) {
        if (!_stopping) {
          AppLogController.instance.record('MESSAGE_RX', 'In-app message listener restarted after error: $error', level: AppLogLevel.warning);
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      } finally {
        final connection = _connection;
        _connection = null;
        if (connection != null && !connection.isClosed) await connection.close();
        final discovery = _discovery;
        _discovery = null;
        if (discovery != null && !discovery.isClosed) await discovery.close();
        final server = _server;
        _server = null;
        if (server != null && !server.isClosed) await server.close();
      }
    }
    AppLogController.instance.record('MESSAGE_RX', 'In-app message listener stopped');
  }

  Future<InternetAddress?> _findWifiAddress() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false, includeLinkLocal: false);
      final candidates = <({int priority, InternetAddress address})>[];
      for (final networkInterface in interfaces) {
        final name = networkInterface.name.toLowerCase();
        final priority = name.contains('wlan') || name.contains('wifi') ? 0 : 1;
        for (final address in networkInterface.addresses) {
          if (_isPrivateIpv4(address)) candidates.add((priority: priority, address: address));
        }
      }
      candidates.sort((a, b) => a.priority.compareTo(b.priority));
      return candidates.isEmpty ? null : candidates.first.address;
    } catch (_) {
      return null;
    }
  }

  bool _isPrivateIpv4(InternetAddress address) {
    final bytes = address.rawAddress;
    if (bytes.length != 4) return false;
    return bytes[0] == 10 || (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) || (bytes[0] == 192 && bytes[1] == 168);
  }
}