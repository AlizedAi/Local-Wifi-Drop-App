import 'dart:convert';
import 'dart:math';

/// Fresh, per-session pairing secrets. The receiver must invalidate these
/// after one successful authentication or any terminal session event.
class PairingCredentials {
  const PairingCredentials._({
    required this.sessionId,
    required this.token,
  });

  static const int sessionIdBytes = 16;
  static const int tokenBytes = 32;

  final String sessionId;
  final String token;

  factory PairingCredentials.generate() {
    final random = Random.secure();
    return PairingCredentials._(
      sessionId: _encodeRandom(random, sessionIdBytes),
      token: _encodeRandom(random, tokenBytes),
    );
  }

  static String _encodeRandom(Random random, int length) {
    final bytes = List<int>.generate(length, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// Compares same-length ASCII secrets without early exit on content.
  ///
  /// Length is public protocol metadata; byte content is compared in one pass.
  static bool constantTimeEquals(String left, String right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var index = 0; index < left.length; index++) {
      difference |= left.codeUnitAt(index) ^ right.codeUnitAt(index);
    }
    return difference == 0;
  }
}
