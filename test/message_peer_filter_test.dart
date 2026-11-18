import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_wifi_drop/src/local_peer_discovery.dart';
import 'package:local_wifi_drop/src/message_peer_filter.dart';

void main() {
  test('filters scanned addresses to live message responders only', () async {
    final lookups = <String>[];
    final result = await MessagePeerFilter(
      peerLookup: (address, port, purpose, timeout) async {
        lookups.add(address.address);
        expect(port, LocalPeerDiscoveryClient.messagePort);
        expect(purpose, 'message');
        expect(timeout, const Duration(milliseconds: 700));
        if (address.address == '192.168.1.22') throw const SocketException('offline peer');
        return address.address == '192.168.1.20'
            ? [const DiscoveredMessagePeer(address: '192.168.1.20', port: 34567)]
            : const [];
      },
    ).filter([
      '192.168.1.20', '192.168.1.21', '192.168.1.22', '127.0.0.1', 'not-an-ip',
    ]);
    expect(result, ['192.168.1.20']);
    expect(lookups, containsAll(['192.168.1.20', '192.168.1.21', '192.168.1.22']));
    expect(lookups, hasLength(3));
  });

  test('empty scan returns no message peers without opening discovery sockets', () async {
    var lookupCount = 0;
    final result = await MessagePeerFilter(
      peerLookup: (InternetAddress address, int port, String purpose, Duration timeout) async {
        lookupCount++;
        return const [];
      },
    ).filter(const []);
    expect(result, isEmpty);
    expect(lookupCount, 0);
  });
}
