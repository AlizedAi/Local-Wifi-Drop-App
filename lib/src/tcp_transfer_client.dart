import 'dart:io';
import 'hello_payload.dart';
import 'pairing_invite.dart';
import 'protocol_frame.dart';
import 'tcp_frame_connection.dart';

/// Connects to a parsed local invitation and sends HELLO as the first frame.
class TcpTransferClient {
  static Future<TcpFrameConnection> connect({
    required PairingInvite invitation,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (!invitation.expiresAt.isAfter(DateTime.now().toUtc())) {
      throw const FormatException('Pairing invitation has expired.');
    }
    final socket = await Socket.connect(
      invitation.host, invitation.port, timeout: timeout,
    );
    final connection = TcpFrameConnection.fromSocket(socket);
    try {
      final hello = HelloPayload.fromEncodedCredentials(
        sessionId: invitation.sessionId, token: invitation.token,
      );
      await connection.sendFrame(
        ProtocolFrame(ProtocolMessageType.hello, hello.encode()),
      );
      return connection;
    } on Object {
      await connection.close();
      rethrow;
    }
  }
}
