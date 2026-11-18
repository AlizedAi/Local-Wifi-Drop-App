import 'package:flutter_test/flutter_test.dart';
import 'package:local_wifi_drop/src/pairing_invite.dart';
import 'package:local_wifi_drop/src/receiver_invitation.dart';

void main() {
  group('ReceiverInvitation', () {
    final now = DateTime.utc(2026, 11, 8, 12);
    test('creates a plain-TCP invitation accepted by the parser', () {
      final invitation = ReceiverInvitation.create(
        host: '192.168.1.25', port: 45123, now: now,
      );
      final parsed = PairingInvite.parse(invitation.uri.toString(), now: now);
      expect(parsed.host, '192.168.1.25');
      expect(parsed.port, 45123);
      expect(parsed.sessionId, invitation.credentials.sessionId);
      expect(parsed.token, invitation.credentials.token);
      expect(parsed.expiresAt, now.add(const Duration(minutes: 2)));
    });
    test('rejects invalid host and port', () {
      expect(() => ReceiverInvitation.create(
        host: '8.8.8.8', port: 45123, now: now,
      ), throwsFormatException);
      expect(() => ReceiverInvitation.create(
        host: '192.168.1.25', port: 80, now: now,
      ), throwsFormatException);
    });
    test('rejects an excessive lifetime', () {
      expect(() => ReceiverInvitation.create(
        host: '192.168.1.25', port: 45123, now: now,
        lifetime: const Duration(minutes: 6),
      ), throwsFormatException);
    });
  });
}
