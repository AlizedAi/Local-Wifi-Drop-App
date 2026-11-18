import 'dart:io';

import 'local_peer_discovery.dart';

typedef MessagePeerFilterLookup = Future<List<DiscoveredMessagePeer>> Function(
  InternetAddress address,
  int port,
  String purpose,
  Duration timeout,
);

/// Keeps only private IPv4 addresses with a live message-service responder.
class MessagePeerFilter {
  const MessagePeerFilter({
    LocalPeerDiscoveryClient discovery = const LocalPeerDiscoveryClient(),
    MessagePeerFilterLookup? peerLookup,
    this.timeout = const Duration(milliseconds: 700),
  })  : _discovery = discovery,
        _peerLookup = peerLookup;

  final LocalPeerDiscoveryClient _discovery;
  final MessagePeerFilterLookup? _peerLookup;
  final Duration timeout;

  Future<List<String>> filter(List<String> candidates) async {
    final results = await Future.wait(candidates.map((candidate) async {
      final address = InternetAddress.tryParse(candidate);
      if (address == null || !_isPrivateIpv4(address)) return null;
      try {
        final lookup = _peerLookup;
        final peers = lookup != null
            ? await lookup(address, LocalPeerDiscoveryClient.messagePort, 'message', timeout)
            : await _discovery.discoverMessagePeers(
                targetAddress: address,
                timeout: timeout,
              );
        return peers.any((peer) => peer.address == address.address)
            ? address.address
            : null;
      } catch (_) {
        return null;
      }
    }));
    return results.whereType<String>().toList(growable: false);
  }

  bool _isPrivateIpv4(InternetAddress address) {
    if (address.type != InternetAddressType.IPv4) return false;
    final bytes = address.rawAddress;
    return bytes[0] == 10 ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
        (bytes[0] == 192 && bytes[1] == 168);
  }
}
