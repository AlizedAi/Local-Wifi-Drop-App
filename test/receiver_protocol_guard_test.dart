import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_wifi_drop/src/protocol_frame.dart';
import 'package:local_wifi_drop/src/receiver_protocol_guard.dart';
import 'package:local_wifi_drop/src/transfer_manifest.dart';

void main() {
  final manifest = TransferManifest(
    batchId: List<int>.filled(16, 3),
    files: [
      TransferFileEntry(name: 'zero.bin', size: 0),
      TransferFileEntry(name: 'small.bin', size: 3),
    ],
  );

  ProtocolFrame fileBegin(int index, int size) {
    final payload = Uint8List(12);
    final data = ByteData.sublistView(payload);
    data.setUint32(0, index, Endian.big);
    data.setUint64(4, size, Endian.big);
    return ProtocolFrame(ProtocolMessageType.fileBegin, payload);
  }

  ProtocolFrame fileEnd(int index) {
    return ProtocolFrame(ProtocolMessageType.fileEnd, FileEndPayload(fileIndex: index, digest: List<int>.filled(32, 0)).encodePayload());
  }

  ReceiverProtocolGuard readyToApprove() {
    final guard = ReceiverProtocolGuard();
    guard.markHelloAuthenticated();
    guard.receiveManifest(manifest);
    return guard;
  }

  ReceiverProtocolGuard readyToTransfer() {
    final guard = readyToApprove();
    guard.approve();
    return guard;
  }

  group('ReceiverProtocolGuard', () {
    test('requires authenticated HELLO before manifest', () {
      final guard = ReceiverProtocolGuard();

      expect(() => guard.receiveManifest(manifest), throwsStateError);
      expect(guard.phase, ReceiverProtocolPhase.awaitingHello);
    });

    test('requires receiver approval before file data', () {
      final guard = readyToApprove();

      expect(
        () => guard.receiveFrame(fileBegin(0, 0)),
        throwsFormatException,
      );
      expect(guard.phase, ReceiverProtocolPhase.failed);
    });

    test('accepts ordered files and completes the batch', () {
      final guard = readyToTransfer();

      guard.receiveFrame(fileBegin(0, 0));
      guard.receiveFrame(fileEnd(0));
      guard.receiveFrame(fileBegin(1, 3));
      guard.receiveFrame(ProtocolFrame(
        ProtocolMessageType.fileData,
        FileDataChunk(
          fileIndex: 1,
          offset: 0,
          data: [1, 2, 3],
        ).encodePayload(),
      ));
      guard.receiveFrame(fileEnd(1));
      guard.receiveFrame(ProtocolFrame(ProtocolMessageType.batchDone, []));

      expect(guard.phase, ReceiverProtocolPhase.completed);
    });

    test('rejects an out-of-order file index', () {
      final guard = readyToTransfer();

      expect(
        () => guard.receiveFrame(fileBegin(1, 3)),
        throwsFormatException,
      );
      expect(guard.phase, ReceiverProtocolPhase.failed);
    });

    test('rejects a mismatched file size', () {
      final guard = readyToTransfer();

      expect(
        () => guard.receiveFrame(fileBegin(0, 1)),
        throwsFormatException,
      );
    });

    test('rejects data with a skipped offset', () {
      final guard = readyToTransfer();
      guard.receiveFrame(fileBegin(0, 0));
      guard.receiveFrame(fileEnd(0));
      guard.receiveFrame(fileBegin(1, 3));

      expect(
        () => guard.receiveFrame(ProtocolFrame(
          ProtocolMessageType.fileData,
          FileDataChunk(fileIndex: 1, offset: 1, data: [1]).encodePayload(),
        )),
        throwsFormatException,
      );
    });

    test('rejects data beyond the manifest size', () {
      final guard = readyToTransfer();
      guard.receiveFrame(fileBegin(0, 0));
      guard.receiveFrame(fileEnd(0));
      guard.receiveFrame(fileBegin(1, 3));

      expect(
        () => guard.receiveFrame(ProtocolFrame(
          ProtocolMessageType.fileData,
          FileDataChunk(
            fileIndex: 1,
            offset: 0,
            data: [1, 2, 3, 4],
          ).encodePayload(),
        )),
        throwsFormatException,
      );
    });

    test('rejects FILE_END before the exact size is received', () {
      final guard = readyToTransfer();
      guard.receiveFrame(fileBegin(0, 0));
      guard.receiveFrame(fileEnd(0));
      guard.receiveFrame(fileBegin(1, 3));
      guard.receiveFrame(ProtocolFrame(
        ProtocolMessageType.fileData,
        FileDataChunk(fileIndex: 1, offset: 0, data: [1]).encodePayload(),
      ));

      expect(() => guard.receiveFrame(fileEnd(1)), throwsFormatException);
    });

    test('rejects BATCH_DONE while files remain', () {
      final guard = readyToTransfer();

      expect(
        () => guard.receiveFrame(ProtocolFrame(ProtocolMessageType.batchDone, [])),
        throwsFormatException,
      );
    });

    test('allows cancellation before and during transfer', () {
      final waiting = readyToApprove();
      waiting.receiveFrame(ProtocolFrame(ProtocolMessageType.cancel, []));
      expect(waiting.phase, ReceiverProtocolPhase.cancelled);

      final active = readyToTransfer();
      active.receiveFrame(fileBegin(0, 0));
      active.receiveFrame(ProtocolFrame(ProtocolMessageType.cancel, []));
      expect(active.phase, ReceiverProtocolPhase.cancelled);
    });

    test('rejects the batch only while awaiting approval', () {
      final guard = readyToApprove();
      guard.reject();
      expect(guard.phase, ReceiverProtocolPhase.rejected);
    });
  });
}
