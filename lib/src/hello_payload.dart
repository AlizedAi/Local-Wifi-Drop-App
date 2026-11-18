import 'dart:convert';
import 'dart:typed_data';

/// Versioned HELLO payload sent as the first frame on the local TCP connection.
///
/// Layout: uint8 protocol version, 16-byte session ID, 32-byte one-time token.
class HelloPayload {
  factory HelloPayload({
    required List<int> sessionId,
    required List<int> token,
  }) {
    if (sessionId.length != sessionIdBytes ||
        sessionId.any((byte) => byte < 0 || byte > 255)) {
      throw const FormatException('HELLO session ID must contain 16 bytes.');
    }
    if (token.length != tokenBytes ||
        token.any((byte) => byte < 0 || byte > 255)) {
      throw const FormatException('HELLO token must contain 32 bytes.');
    }
    return HelloPayload._(
      sessionId: List<int>.unmodifiable(sessionId),
      token: List<int>.unmodifiable(token),
    );
  }

  const HelloPayload._({required this.sessionId, required this.token});

  static const int protocolVersion = 2;
  static const int sessionIdBytes = 16;
  static const int tokenBytes = 32;
  static const int payloadBytes = 1 + sessionIdBytes + tokenBytes;

  final List<int> sessionId;
  final List<int> token;

  factory HelloPayload.fromEncodedCredentials({
    required String sessionId,
    required String token,
  }) {
    try {
      final sessionBytes = base64Url.decode(base64Url.normalize(sessionId));
      final tokenBytesDecoded = base64Url.decode(base64Url.normalize(token));
      final canonicalSession =
          base64Url.encode(sessionBytes).replaceAll('=', '');
      final canonicalToken =
          base64Url.encode(tokenBytesDecoded).replaceAll('=', '');
      if (canonicalSession != sessionId || canonicalToken != token) {
        throw const FormatException('HELLO credentials are not canonical.');
      }
      return HelloPayload(
        sessionId: sessionBytes,
        token: tokenBytesDecoded,
      );
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('HELLO credentials are malformed.');
    }
  }

  Uint8List encode() {
    final output = Uint8List(payloadBytes);
    output[0] = protocolVersion;
    output.setRange(1, 1 + sessionIdBytes, sessionId);
    output.setRange(1 + sessionIdBytes, payloadBytes, token);
    return output;
  }

  static HelloPayload decode(List<int> payload) {
    if (payload.length != payloadBytes ||
        payload.any((byte) => byte < 0 || byte > 255)) {
      throw const FormatException('HELLO payload length or bytes are invalid.');
    }
    if (payload[0] != protocolVersion) {
      throw const FormatException('Unsupported HELLO protocol version.');
    }
    return HelloPayload(
      sessionId: payload.sublist(1, 1 + sessionIdBytes),
      token: payload.sublist(1 + sessionIdBytes),
    );
  }

  String get encodedSessionId =>
      base64Url.encode(sessionId).replaceAll('=', '');

  String get encodedToken => base64Url.encode(token).replaceAll('=', '');
}
