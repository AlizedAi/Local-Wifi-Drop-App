import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'pairing_invite.dart';

const String serviceName = 'local-wifi-drop';
const int protocolVersion = 1;

/// A file-transfer peer, which uses a short-lived pairing invitation.
class DiscoveredPeer {
  const DiscoveredPeer({required this.invitation});
  final PairingInvite invitation;
  String get address => invitation.host;
}

/// A message peer, identified only by its LAN IP and open TCP message port.
class DiscoveredMessagePeer {
  const DiscoveredMessagePeer({required this.address, required this.port});
  final String address;
  final int port;
}

/// UDP responder for devices actively running Local WiFi Drop.
class LocalPeerDiscoveryResponder {
  LocalPeerDiscoveryResponder._(this._socket, this._subscription);

  static const int defaultPort = 39475;
  static const int messagePort = 39476;

  final RawDatagramSocket _socket;
  final StreamSubscription<RawSocketEvent> _subscription;
  bool _closed = false;

  int get port => _socket.port;
  bool get isClosed => _closed;

  static Future<LocalPeerDiscoveryResponder> start({
    Uri? invitation,
    String? messageHost,
    int? messageTcpPort,
    InternetAddress? bindAddress,
    int port = defaultPort,
    String? acceptedPurpose,
  }) async {
    final isMessageEndpoint = messageHost != null || messageTcpPort != null;
    if ((invitation == null) == !isMessageEndpoint ||
        (isMessageEndpoint && (messageHost == null || messageTcpPort == null))) {
      throw ArgumentError('Provide either an invitation or a message host and TCP port.');
    }
    if (messageTcpPort != null && (messageTcpPort < 1 || messageTcpPort > 65535)) {
      throw ArgumentError.value(messageTcpPort, 'messageTcpPort');
    }
    if (port < 0 || port > 65535) {
      throw ArgumentError.value(port, 'port');
    }

    final socket = await RawDatagramSocket.bind(
      bindAddress ?? InternetAddress.anyIPv4,
      port,
      reuseAddress: true,
      reusePort: true,
    );
    final invitationText = invitation?.toString();
    final subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      while (true) {
        final packet = socket.receive();
        if (packet == null) break;
        final request = _decodeJson(packet.data);
        if (request == null ||
            request['service'] != serviceName ||
            request['version'] != protocolVersion ||
            request['type'] != 'discover' ||
            (acceptedPurpose != null && request['purpose'] != acceptedPurpose)) {
          continue;
        }
        final nonce = request['nonce'];
        if (nonce is! String ||
            nonce.length < 8 ||
            nonce.length > 64 ||
            !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(nonce)) {
          continue;
        }

        final response = <String, Object?>{
          'service': serviceName,
          'version': protocolVersion,
          'type': 'peer',
          'nonce': nonce,
        };
        if (invitationText != null) {
          response['invitation'] = invitationText;
        } else {
          response['host'] = messageHost;
          response['tcpPort'] = messageTcpPort;
        }
        socket.send(utf8.encode(jsonEncode(response)), packet.address, packet.port);
      }
    });
    return LocalPeerDiscoveryResponder._(socket, subscription);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription.cancel();
    _socket.close();
  }
}

/// Performs bounded UDP discovery scans for file and message endpoints.
class LocalPeerDiscoveryClient {
  const LocalPeerDiscoveryClient();

  static const int defaultPort = LocalPeerDiscoveryResponder.defaultPort;
  static const int messagePort = LocalPeerDiscoveryResponder.messagePort;

  Future<List<DiscoveredPeer>> discover({
    InternetAddress? targetAddress,
    int port = defaultPort,
    Duration timeout = const Duration(milliseconds: 1400),
    String? purpose,
  }) async {
    final packets = await _discoverResponses(
      targetAddress: targetAddress,
      port: port,
      timeout: timeout,
      purpose: purpose,
    );
    final peers = <String, DiscoveredPeer>{};
    for (final response in packets) {
      if (response['invitation'] is! String) continue;
      try {
        final invitation = PairingInvite.parse(response['invitation'] as String);
        peers[invitation.host] = DiscoveredPeer(invitation: invitation);
      } on FormatException {
        // Ignore malformed or expired file invitations.
      }
    }
    return List<DiscoveredPeer>.unmodifiable(peers.values);
  }

  Future<List<DiscoveredMessagePeer>> discoverMessagePeers({
    InternetAddress? targetAddress,
    Duration timeout = const Duration(milliseconds: 1400),
  }) async {
    final packets = await _discoverResponses(
      targetAddress: targetAddress,
      port: messagePort,
      timeout: timeout,
      purpose: 'message',
    );
    final peers = <String, DiscoveredMessagePeer>{};
    for (final response in packets) {
      final host = response['host'];
      final tcpPort = response['tcpPort'];
      if (host is! String ||
          tcpPort is! int ||
          tcpPort < 1 ||
          tcpPort > 65535) {
        continue;
      }
      final address = InternetAddress.tryParse(host);
      if (address == null ||
          address.type != InternetAddressType.IPv4 ||
          !_isPrivateIpv4(address)) {
        continue;
      }
      peers[address.address] =
          DiscoveredMessagePeer(address: address.address, port: tcpPort);
    }
    return List<DiscoveredMessagePeer>.unmodifiable(peers.values);
  }

  Future<List<Map<String, dynamic>>> _discoverResponses({
    required InternetAddress? targetAddress,
    required int port,
    required Duration timeout,
    required String? purpose,
  }) async {
    if (port < 1 || port > 65535) {
      throw ArgumentError.value(port, 'port');
    }
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout');
    }

    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final nonce = _createNonce();
    final request = utf8.encode(jsonEncode({
      'service': serviceName,
      'version': protocolVersion,
      'type': 'discover',
      'purpose': purpose,
      'nonce': nonce,
    }));
    final responses = <Map<String, dynamic>>[];
    final destination = targetAddress ?? InternetAddress('255.255.255.255');
    try {
      if (targetAddress == null) socket.broadcastEnabled = true;
      // Start listening before sending. A fast responder can reply immediately;
      // registering the listener afterwards can otherwise lose the first packet.
      final subscription = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        while (true) {
          final packet = socket.receive();
          if (packet == null) break;
          final response = _decodeJson(packet.data);
          if (response == null ||
              response['service'] != serviceName ||
              response['version'] != protocolVersion ||
              response['type'] != 'peer' ||
              response['nonce'] != nonce) {
            continue;
          }
          responses.add(response);
        }
      });
      socket.send(request, destination, port);
      try {
        await Future<void>.delayed(timeout);
      } finally {
        await subscription.cancel();
      }
    } finally {
      socket.close();
    }
    return responses;
  }

  String _createNonce() {
    final random = Random.secure();
    return List<int>.generate(12, (_) => random.nextInt(256))
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  static bool _isPrivateIpv4(InternetAddress address) {
    final b = address.rawAddress;
    return b.length == 4 &&
        (b[0] == 10 ||
            (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
            (b[0] == 192 && b[1] == 168));
  }
}

Map<String, dynamic>? _decodeJson(List<int> bytes) {
  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is Map<String, dynamic>) return decoded;
  } on FormatException {
    return null;
  }
  return null;
}
