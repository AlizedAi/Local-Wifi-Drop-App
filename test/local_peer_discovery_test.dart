import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_wifi_drop/src/local_peer_discovery.dart';
import 'package:local_wifi_drop/src/receiver_invitation.dart';

void main() {
  group('LocalPeerDiscovery', () {
    test('discovers a file peer and returns its invitation', () async {
      final invitation = ReceiverInvitation.create(host: '192.168.1.22', port: 34567);
      final responder = await LocalPeerDiscoveryResponder.start(
        invitation: invitation.uri,
        bindAddress: InternetAddress.loopbackIPv4,
        port: 0,
      );
      try {
        final peers = await const LocalPeerDiscoveryClient().discover(
          targetAddress: InternetAddress.loopbackIPv4,
          port: responder.port,
          timeout: const Duration(milliseconds: 100),
        );
        expect(peers, hasLength(1));
        expect(peers.single.address, '192.168.1.22');
        expect(peers.single.invitation.port, 34567);
      } finally {
        await responder.close();
      }
      expect(responder.isClosed, isTrue);
    });

    test('discovers a message peer using only its IP and open TCP port', () async {
      final responder = await LocalPeerDiscoveryResponder.start(
        messageHost: '192.168.1.22',
        messageTcpPort: 34567,
        acceptedPurpose: 'message',
        bindAddress: InternetAddress.loopbackIPv4,
        port: LocalPeerDiscoveryClient.messagePort,
      );
      try {
        final peers = await const LocalPeerDiscoveryClient().discoverMessagePeers(
          targetAddress: InternetAddress.loopbackIPv4,
          timeout: const Duration(milliseconds: 100),
        );
        expect(peers, hasLength(1));
        expect(peers.single.address, '192.168.1.22');
        expect(peers.single.port, 34567);
      } finally {
        await responder.close();
      }
    });

    test('returns empty when no app peer responds', () async {
      final peers = await const LocalPeerDiscoveryClient().discover(
        targetAddress: InternetAddress.loopbackIPv4,
        port: 39476,
        timeout: const Duration(milliseconds: 40),
      );
      expect(peers, isEmpty);
    });
  });
}
