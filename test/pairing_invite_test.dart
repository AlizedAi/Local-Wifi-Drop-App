import 'package:flutter_test/flutter_test.dart';
import 'package:local_wifi_drop/src/pairing_invite.dart';

void main() {
  group('PairingInvite.parse', () {
    final now = DateTime.utc(2026, 11, 8, 12);
    final expires = now.add(const Duration(minutes: 2)).millisecondsSinceEpoch ~/
        1000;
    final validInvite = Uri(
      scheme: 'lwd',
      host: 'connect',
      queryParameters: {
        'version': '1',
        'host': '192.168.1.25',
        'port': '45123',
        'session': 'AQEBAQEBAQEBAQEBAQEBAQ',
        'token': 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE',
        'expires': '$expires',
      },
    ).toString();

    test('accepts a valid short-lived local invitation', () {
      final invite = PairingInvite.parse(validInvite, now: now);

      expect(invite.host, '192.168.1.25');
      expect(invite.port, 45123);
      expect(invite.expiresAt, now.add(const Duration(minutes: 2)));
    });

    test('rejects invitation credentials below the entropy floor', () {
      final shortSession = Uri.parse(validInvite).replace(
        queryParameters: {
          ...Uri.parse(validInvite).queryParameters,
          'session': 'AbCdEfGhIjKlMnOp',
        },
      );
      final nonCanonicalSession = Uri.parse(validInvite).replace(
        queryParameters: {
          ...Uri.parse(validInvite).queryParameters,
          'session': '${'A' * 21}B',
        },
      );
      final nonCanonicalToken = Uri.parse(validInvite).replace(
        queryParameters: {
          ...Uri.parse(validInvite).queryParameters,
          'token': '${'A' * 42}B',
        },
      );
      final shortToken = Uri.parse(validInvite).replace(
        queryParameters: {
          ...Uri.parse(validInvite).queryParameters,
          'token': 'A' * 32,
        },
      );

      expect(
        () => PairingInvite.parse(shortSession.toString(), now: now),
        throwsFormatException,
      );
      expect(
        () => PairingInvite.parse(shortToken.toString(), now: now),
        throwsFormatException,
      );
      expect(
        () => PairingInvite.parse(nonCanonicalSession.toString(), now: now),
        throwsFormatException,
      );
      expect(
        () => PairingInvite.parse(nonCanonicalToken.toString(), now: now),
        throwsFormatException,
      );
    });

    test('rejects a public address', () {
      final uri = Uri.parse(validInvite).replace(
        queryParameters: {
          ...Uri.parse(validInvite).queryParameters,
          'host': '8.8.8.8',
        },
      );

      expect(
        () => PairingInvite.parse(uri.toString(), now: now),
        throwsFormatException,
      );
    });

    test('rejects an expired invitation', () {
      final uri = Uri.parse(validInvite).replace(
        queryParameters: {
          ...Uri.parse(validInvite).queryParameters,
          'expires': '${now.millisecondsSinceEpoch ~/ 1000 - 1}',
        },
      );

      expect(
        () => PairingInvite.parse(uri.toString(), now: now),
        throwsFormatException,
      );
    });

    test('rejects duplicate fields', () {
      final duplicate = '$validInvite&version=1';

      expect(
        () => PairingInvite.parse(duplicate, now: now),
        throwsFormatException,
      );
    });
  });
}
