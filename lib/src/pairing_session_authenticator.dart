import 'package:local_wifi_drop/src/hello_payload.dart';
import 'package:local_wifi_drop/src/pairing_credentials.dart';

/// Validates one HELLO against a single short-lived receiver invitation.
///
/// The caller must invoke this after accepting a connection on the selected local interface; HELLO token validation follows.
/// A successful authentication consumes the invitation; failed attempts do
/// not consume it. Network-level rate limiting remains the listener's job.
class PairingSessionAuthenticator {
  PairingSessionAuthenticator({
    required PairingCredentials credentials,
    required this.expiresAt,
  }) : _credentials = credentials;

  final PairingCredentials _credentials;
  final DateTime expiresAt;
  bool _consumed = false;

  bool get isConsumed => _consumed;

  bool authenticate(HelloPayload hello, {DateTime? now}) {
    if (_consumed) return false;
    final currentTime = (now ?? DateTime.now()).toUtc();
    if (!expiresAt.isAfter(currentTime)) return false;

    final sessionMatches = PairingCredentials.constantTimeEquals(
      hello.encodedSessionId,
      _credentials.sessionId,
    );
    final tokenMatches = PairingCredentials.constantTimeEquals(
      hello.encodedToken,
      _credentials.token,
    );

    if (!(sessionMatches & tokenMatches)) return false;
    _consumed = true;
    return true;
  }
}
