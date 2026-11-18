import 'dart:io';

import 'local_peer_discovery.dart';
import 'protocol_frame.dart';
import 'tcp_frame_connection.dart';

typedef MessagePeerLookup = Future<List<DiscoveredMessagePeer>> Function(
  InternetAddress address, int port, String purpose, Duration timeout,
);
typedef MessageConnectionFactory = Future<TcpFrameConnection> Function(
  DiscoveredMessagePeer peer,
);

/// Sends a message directly to the selected IP and its advertised open TCP port.
class LocalMessageClient {
  LocalMessageClient({
    LocalPeerDiscoveryClient discovery = const LocalPeerDiscoveryClient(),
    this.discoveryPort = LocalPeerDiscoveryClient.messagePort,
    MessagePeerLookup? peerLookup,
    MessageConnectionFactory? connectionFactory,
  }) : _discovery = discovery, _peerLookup = peerLookup,
       _connectionFactory = connectionFactory;

  final LocalPeerDiscoveryClient _discovery;
  final int discoveryPort;
  final MessagePeerLookup? _peerLookup;
  final MessageConnectionFactory? _connectionFactory;

  Future<List<DiscoveredMessagePeer>> _findPeers(InternetAddress address) {
    const timeout = Duration(milliseconds: 900);
    final lookup = _peerLookup;
    if (lookup != null) return lookup(address, discoveryPort, 'message', timeout);
    return _discovery.discoverMessagePeers(targetAddress: address, timeout: timeout);
  }

  Future<void> sendToAddress(String addressText, String text) async {
    final address = InternetAddress.tryParse(addressText);
    if (address == null || address.type != InternetAddressType.IPv4) {
      throw const FormatException('A valid IPv4 receiver address is required.');
    }
    final payload = TextMessagePayload(text);
    List<DiscoveredMessagePeer> peers = const [];
    for (var attempt = 0; attempt < 3; attempt++) {
      peers = await _findPeers(address);
      if (peers.any((peer) => peer.address == address.address)) break;
      if (attempt < 2) await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    DiscoveredMessagePeer? peer;
    for (final candidate in peers) {
      if (candidate.address == address.address) { peer = candidate; break; }
    }
    if (peer == null) {
      throw SocketException('No online Local WiFi Drop message receiver responded at ${address.address}.');
    }

    TcpFrameConnection? connection;
    try {
      final connector = _connectionFactory;
      if (connector != null) {
        connection = await connector(peer);
      } else {
        final socket = await Socket.connect(peer.address, peer.port,
          timeout: const Duration(seconds: 10));
        connection = TcpFrameConnection.fromSocket(socket);
      }
      await connection.sendFrame(ProtocolFrame(ProtocolMessageType.textMessage, payload.bytes));
      final response = await connection.readFrame().timeout(const Duration(seconds: 60));
      if (response == null || response.payload.isNotEmpty) {
        throw const FormatException('Receiver did not confirm message storage.');
      }
      if (response.type == ProtocolMessageType.reject) throw StateError('Receiver rejected the message.');
      if (response.type != ProtocolMessageType.accept) {
        throw const FormatException('Unexpected message delivery response.');
      }
    } finally {
      if (connection != null && !connection.isClosed) await connection.close();
    }
  }
}
