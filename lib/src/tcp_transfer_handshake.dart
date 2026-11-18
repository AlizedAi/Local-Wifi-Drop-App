import 'tcp_frame_connection.dart';
import 'protocol_frame.dart';
import 'sender_protocol_guard.dart';
import 'transfer_manifest.dart';

class TcpReceiverHandshake {
  static Future<bool> receiveManifestAndRequestApproval({
    required TcpFrameConnection connection,
    required Future<bool> Function(TransferManifest manifest) approve,
    ProtocolFrame? initialFrame,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final frame = initialFrame ?? await connection.readFrame().timeout(timeout);
    if (frame == null || frame.type != ProtocolMessageType.manifest) {
      throw const FormatException('Expected MANIFEST before receiver approval.');
    }
    final manifest = TransferManifest.decode(frame.payload);
    final accepted = await approve(manifest);
    await connection.sendFrame(ProtocolFrame(
      accepted ? ProtocolMessageType.accept : ProtocolMessageType.reject,
      const [],
    ));
    return accepted;
  }
}

class TcpSenderHandshake {
  static Future<bool> sendManifestAndAwaitDecision({
    required TcpFrameConnection connection,
    required TransferManifest manifest,
    SenderProtocolGuard? guard,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final protocolGuard = guard ?? SenderProtocolGuard(manifest: manifest);
    await connection.sendFrame(
      ProtocolFrame(ProtocolMessageType.manifest, manifest.encode()),
    );
    final decision = await connection.readFrame().timeout(timeout);
    if (decision == null) {
      throw const FormatException('Receiver closed before sending a decision.');
    }
    protocolGuard.receiveDecision(decision);
    return protocolGuard.phase == SenderProtocolPhase.transferring;
  }
}
