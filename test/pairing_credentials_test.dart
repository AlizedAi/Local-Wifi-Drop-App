import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_wifi_drop/src/pairing_credentials.dart';

void main() {
  group('PairingCredentials', () {
    test('generates canonical 128-bit session and 256-bit token values', () {
      final credentials = PairingCredentials.generate();

      expect(
        base64Url.decode(base64Url.normalize(credentials.sessionId)),
        hasLength(PairingCredentials.sessionIdBytes),
      );
      expect(
        base64Url.decode(base64Url.normalize(credentials.token)),
        hasLength(PairingCredentials.tokenBytes),
      );
      expect(credentials.sessionId, matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));
      expect(credentials.token, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
    });

    test('compares equal and unequal secrets', () {
      expect(
        PairingCredentials.constantTimeEquals('secret', 'secret'),
        isTrue,
      );
      expect(
        PairingCredentials.constantTimeEquals('secret', 'secreT'),
        isFalse,
      );
      expect(
        PairingCredentials.constantTimeEquals('secret', 'secret-long'),
        isFalse,
      );
    });
  });
}
