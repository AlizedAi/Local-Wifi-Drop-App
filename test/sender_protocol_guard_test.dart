import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_wifi_drop/src/protocol_frame.dart';
import 'package:local_wifi_drop/src/sender_protocol_guard.dart';
import 'package:local_wifi_drop/src/transfer_manifest.dart';

void main() {
  final manifest = TransferManifest(
    batchId: List<int>.filled(16, 4),
    files: [
      TransferFileEntry(
        name: 'empty.dat',
        size: 0,
      ),
      TransferFileEntry(
        name: 'data.bin',
        size: 3,
      ),
    ],
  );

  ProtocolFrame begin(int index, int size) {
    final payload = Uint8List(12);
    final data = ByteData.sublistView(payload);
    data.setUint32(0, index, Endian.big);
    data.setUint64(4, size, Endian.big);
    return ProtocolFrame(ProtocolMessageType.fileBegin, payload);
  }

  ProtocolFrame end(int index) {
    return ProtocolFrame(ProtocolMessageType.fileEnd, FileEndPayload(fileIndex: index, digest: List<int>.filled(32, 0)).encodePayload());
  }

  group('SenderProtocolGuard', () {
    test('blocks all file frames until receiver accepts', () {
      final guard = SenderProtocolGuard(manifest: manifest);

      expect(() => guard.authorizeOutbound(begin(0, 0)), throwsFormatException);
      expect(guard.phase, SenderProtocolPhase.failed);
    });

    test('rejects the receiver decision if it is not ACCEPT or REJECT', () {
      final guard = SenderProtocolGuard(manifest: manifest);

      expect(
        () => guard.receiveDecision(
          ProtocolFrame(ProtocolMessageType.fileOk, []),
        ),
        throwsFormatException,
      );
      expect(guard.phase, SenderProtocolPhase.failed);
    });

    test('rejects a batch and never permits file frames', () {
      final guard = SenderProtocolGuard(manifest: manifest);
      guard.receiveDecision(ProtocolFrame(ProtocolMessageType.reject, []));

      expect(guard.phase, SenderProtocolPhase.rejected);
      expect(() => guard.authorizeOutbound(begin(0, 0)), throwsFormatException);
    });

    test('allows ordered file frames only after ACCEPT', () {
      final guard = SenderProtocolGuard(manifest: manifest);
      guard.receiveDecision(ProtocolFrame(ProtocolMessageType.accept, []));

      guard.authorizeOutbound(begin(0, 0));
      guard.authorizeOutbound(end(0));
      guard.authorizeOutbound(begin(1, 3));
      guard.authorizeOutbound(ProtocolFrame(
        ProtocolMessageType.fileData,
        FileDataChunk(fileIndex: 1, offset: 0, data: [7, 8, 9]).encodePayload(),
      ));
      guard.authorizeOutbound(end(1));
      guard.authorizeOutbound(ProtocolFrame(ProtocolMessageType.batchDone, []));

      expect(guard.phase, SenderProtocolPhase.completed);
    });

    test('rejects wrong file order, skipped offsets, and early FILE_END', () {
      final wrongOrder = SenderProtocolGuard(manifest: manifest);
      wrongOrder.receiveDecision(ProtocolFrame(ProtocolMessageType.accept, []));
      expect(() => wrongOrder.authorizeOutbound(begin(1, 3)), throwsFormatException);

      final skippedOffset = SenderProtocolGuard(manifest: manifest);
      skippedOffset.receiveDecision(ProtocolFrame(ProtocolMessageType.accept, []));
      skippedOffset.authorizeOutbound(begin(0, 0));
      skippedOffset.authorizeOutbound(end(0));
      skippedOffset.authorizeOutbound(begin(1, 3));
      expect(
        () => skippedOffset.authorizeOutbound(ProtocolFrame(
          ProtocolMessageType.fileData,
          FileDataChunk(fileIndex: 1, offset: 1, data: [7]).encodePayload(),
        )),
        throwsFormatException,
      );

      final earlyEnd = SenderProtocolGuard(manifest: manifest);
      earlyEnd.receiveDecision(ProtocolFrame(ProtocolMessageType.accept, []));
      earlyEnd.authorizeOutbound(begin(0, 0));
      earlyEnd.authorizeOutbound(end(0));
      earlyEnd.authorizeOutbound(begin(1, 3));
      earlyEnd.authorizeOutbound(ProtocolFrame(
        ProtocolMessageType.fileData,
        FileDataChunk(fileIndex: 1, offset: 0, data: [7]).encodePayload(),
      ));
      expect(() => earlyEnd.authorizeOutbound(end(1)), throwsFormatException);
    });

    test('allows cancellation before and during transfer', () {
      final waiting = SenderProtocolGuard(manifest: manifest);
      waiting.authorizeOutbound(ProtocolFrame(ProtocolMessageType.cancel, []));
      expect(waiting.phase, SenderProtocolPhase.cancelled);

      final active = SenderProtocolGuard(manifest: manifest);
      active.receiveDecision(ProtocolFrame(ProtocolMessageType.accept, []));
      active.authorizeOutbound(begin(0, 0));
      active.authorizeOutbound(ProtocolFrame(ProtocolMessageType.cancel, []));
      expect(active.phase, SenderProtocolPhase.cancelled);
    });
  });
}
