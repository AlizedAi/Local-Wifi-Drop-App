import 'package:flutter_test/flutter_test.dart';
import 'package:local_wifi_drop/src/hello_payload.dart';
import 'package:local_wifi_drop/src/pairing_credentials.dart';
import 'package:local_wifi_drop/src/pairing_session_authenticator.dart';

void main() {
  group('HelloPayload', () {
    test('encodes and decodes the versioned fixed-size payload', () {
      final original = HelloPayload(
        sessionId: List<int>.generate(16, (index) => index),
        token: List<int>.generate(32, (index) => 255 - index),
      );
      final decoded = HelloPayload.decode(original.encode());

      expect(decoded.sessionId, original.sessionId);
      expect(decoded.token, original.token);
      expect(original.encode(), hasLength(HelloPayload.payloadBytes));
      expect(original.encode().first, HelloPayload.protocolVersion);
    });

    test('rejects wrong payload length and unsupported version', () {
      expect(() => HelloPayload.decode(List<int>.filled(48, 0)),
          throwsFormatException);
      expect(() => HelloPayload.decode(List<int>.filled(50, 0)),
          throwsFormatException);

      final unsupported = HelloPayload(
        sessionId: List<int>.filled(16, 1),
        token: List<int>.filled(32, 2),
      ).encode()
        ..[0] = HelloPayload.protocolVersion + 1;
      expect(() => HelloPayload.decode(unsupported), throwsFormatException);
    });

    test('rejects malformed or non-canonical encoded credentials', () {
      expect(
        () => HelloPayload.fromEncodedCredentials(
          sessionId: 'not-a-session',
          token: 'not-a-token',
        ),
        throwsFormatException,
      );
      expect(
        () => HelloPayload.fromEncodedCredentials(
          sessionId: 'AQEBAQEBAQEBAQEBAQEBAQ==',
          token: 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE',
        ),
        throwsFormatException,
      );
    });
  });

  group('PairingSessionAuthenticator', () {
    final now = DateTime.utc(2026, 11, 8, 12);

    test('accepts matching credentials exactly once', () {
      final credentials = PairingCredentials.generate();
      final authenticator = PairingSessionAuthenticator(
        credentials: credentials,
        expiresAt: now.add(const Duration(minutes: 2)),
      );
      final hello = HelloPayload.fromEncodedCredentials(
        sessionId: credentials.sessionId,
        token: credentials.token,
      );

      expect(authenticator.authenticate(hello, now: now), isTrue);
      expect(authenticator.isConsumed, isTrue);
      expect(authenticator.authenticate(hello, now: now), isFalse);
    });

    test('rejects wrong session or token without consuming invitation', () {
      final credentials = PairingCredentials.generate();
      final other = PairingCredentials.generate();
      final authenticator = PairingSessionAuthenticator(
        credentials: credentials,
        expiresAt: now.add(const Duration(minutes: 2)),
      );
      final wrongSession = HelloPayload.fromEncodedCredentials(
        sessionId: other.sessionId,
        token: credentials.token,
      );
      final wrongToken = HelloPayload.fromEncodedCredentials(
        sessionId: credentials.sessionId,
        token: other.token,
      );

      expect(authenticator.authenticate(wrongSession, now: now), isFalse);
      expect(authenticator.authenticate(wrongToken, now: now), isFalse);
      expect(authenticator.isConsumed, isFalse);
    });

    test('rejects expired invitations', () {
      final credentials = PairingCredentials.generate();
      final authenticator = PairingSessionAuthenticator(
        credentials: credentials,
        expiresAt: now,
      );
      final hello = HelloPayload.fromEncodedCredentials(
        sessionId: credentials.sessionId,
        token: credentials.token,
      );

      expect(authenticator.authenticate(hello, now: now), isFalse);
      expect(authenticator.isConsumed, isFalse);
    });
  });
}
