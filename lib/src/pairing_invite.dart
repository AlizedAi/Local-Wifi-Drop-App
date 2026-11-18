import 'dart:convert';
import 'dart:io';

/// Short-lived invitation for a direct local-network connection.
class PairingInvite {
  const PairingInvite({
    required this.host,
    required this.port,
    required this.sessionId,
    required this.token,
    required this.expiresAt,
  });
  final String host;
  final int port;
  final String sessionId;
  final String token;
  final DateTime expiresAt;
  static const scheme = 'lwd';

  static PairingInvite parse(String raw, {DateTime? now}) {
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme != scheme || uri.host != 'connect' ||
        uri.path.isNotEmpty || uri.userInfo.isNotEmpty || uri.fragment.isNotEmpty) {
      throw const FormatException('This is not a Local WiFi Drop invitation.');
    }
    const keys = {'version', 'host', 'port', 'session', 'token', 'expires'};
    final all = uri.queryParametersAll;
    if (all.keys.toSet().difference(keys).isNotEmpty ||
        keys.any((key) => all[key]?.length != 1)) {
      throw const FormatException('Invitation fields are missing or duplicated.');
    }
    final query = uri.queryParameters;
    if (query['version'] != '1') throw const FormatException('Unsupported invitation version.');
    final host = query['host']!;
    final address = InternetAddress.tryParse(host);
    if (address == null || !_isLocalAddress(address)) {
      throw const FormatException('Invitation address is not a local IP address.');
    }
    final port = int.tryParse(query['port']!);
    if (port == null || port < 1024 || port > 65535) {
      throw const FormatException('Invitation port is invalid.');
    }
    final session = query['session']!;
    if (!RegExp(r'^[A-Za-z0-9_-]{22,64}$').hasMatch(session) ||
        !_hasCanonicalBase64Url(session, 16)) {
      throw const FormatException('Invitation session identifier is invalid.');
    }
    final token = query['token']!;
    if (!RegExp(r'^[A-Za-z0-9_-]{43,128}$').hasMatch(token) ||
        !_hasCanonicalBase64Url(token, 32)) {
      throw const FormatException('Invitation token is invalid.');
    }
    final seconds = int.tryParse(query['expires']!);
    if (seconds == null) throw const FormatException('Invitation expiry is invalid.');
    final expires = DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
    final current = now ?? DateTime.now().toUtc();
    if (!expires.isAfter(current) ||
        expires.isAfter(current.add(const Duration(minutes: 5)))) {
      throw const FormatException('Invitation has expired or is too long-lived.');
    }
    return PairingInvite(
      host: host, port: port, sessionId: session, token: token, expiresAt: expires,
    );
  }

  static bool _hasCanonicalBase64Url(String value, int expectedBytes) {
    try {
      final decoded = base64Url.decode(base64Url.normalize(value));
      return decoded.length == expectedBytes &&
          base64Url.encode(decoded).replaceAll('=', '') == value;
    } on FormatException {
      return false;
    }
  }
  static bool _isLocalAddress(InternetAddress address) {
    final b = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      final a = b[0], second = b[1];
      return a == 10 || (a == 172 && second >= 16 && second <= 31) ||
          (a == 192 && second == 168) || (a == 169 && second == 254);
    }
    if (address.type == InternetAddressType.IPv6) {
      return (b[0] & 0xfe) == 0xfc ||
          (b[0] == 0xfe && (b[1] & 0xc0) == 0x80);
    }
    return false;
  }
}
