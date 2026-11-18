import 'package:local_wifi_drop/src/pairing_credentials.dart';
import 'package:local_wifi_drop/src/pairing_invite.dart';

/// A short-lived invitation. Bind the listener before publishing its URI.
class ReceiverInvitation {
  ReceiverInvitation._({
    required this.credentials,
    required this.expiresAt,
    required this.uri,
  });
  final PairingCredentials credentials;
  final DateTime expiresAt;
  final Uri uri;

  factory ReceiverInvitation.create({
    required String host,
    required int port,
    DateTime? now,
    Duration lifetime = const Duration(minutes: 2),
  }) {
    final rawNow = (now ?? DateTime.now()).toUtc();
    final createdAt = DateTime.fromMillisecondsSinceEpoch(
      (rawNow.millisecondsSinceEpoch ~/ 1000) * 1000, isUtc: true,
    );
    if (lifetime < const Duration(seconds: 1) ||
        lifetime.inMilliseconds % 1000 != 0 ||
        lifetime > const Duration(minutes: 5)) {
      throw const FormatException('Invitation lifetime is outside the allowed range.');
    }
    final expiresAt = createdAt.add(lifetime);
    final credentials = PairingCredentials.generate();
    final uri = Uri(
      scheme: PairingInvite.scheme,
      host: 'connect',
      queryParameters: {
        'version': '1',
        'host': host,
        'port': '$port',
        'session': credentials.sessionId,
        'token': credentials.token,
        'expires': '${expiresAt.millisecondsSinceEpoch ~/ 1000}',
      },
    );
    PairingInvite.parse(uri.toString(), now: createdAt);
    return ReceiverInvitation._(
      credentials: credentials, expiresAt: expiresAt, uri: uri,
    );
  }
}
