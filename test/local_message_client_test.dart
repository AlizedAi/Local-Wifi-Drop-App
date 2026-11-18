import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_wifi_drop/src/local_message_client.dart';
import 'package:local_wifi_drop/src/local_peer_discovery.dart';
import 'package:local_wifi_drop/src/protocol_frame.dart';
import 'package:local_wifi_drop/src/tcp_transfer_server.dart';

void main() {
  test('message transport connects directly to discovered IP and TCP port', () async {
    final server = await TcpTransferServer.bind(address: InternetAddress.loopbackIPv4);
    var lookupCount = 0;
    final received = () async {
      final connection = await server.accept(timeout: const Duration(seconds: 5));
      try {
        final frame = await connection.readFrame().timeout(const Duration(seconds: 5));
        expect(frame?.type, ProtocolMessageType.textMessage);
        expect(TextMessagePayload.decode(frame!.payload).text, 'hello');
        await connection.sendFrame(ProtocolFrame(ProtocolMessageType.accept, const []));
      } finally {
        await connection.close();
      }
    }();

    try {
      await LocalMessageClient(
        discoveryPort: LocalPeerDiscoveryClient.messagePort,
        peerLookup: (address, port, purpose, timeout) async {
          lookupCount++;
          expect(address.address, '127.0.0.1');
          expect(port, LocalPeerDiscoveryClient.messagePort);
          expect(purpose, 'message');
          return [DiscoveredMessagePeer(address: '127.0.0.1', port: server.port)];
        },
      ).sendToAddress('127.0.0.1', 'hello');
      await received;
      expect(lookupCount, 1);
    } finally {
      await server.close();
    }
  });

  test('message discovery uses a port separate from file discovery', () {
    expect(LocalPeerDiscoveryClient.messagePort,
        isNot(LocalPeerDiscoveryClient.defaultPort));
  });
}
