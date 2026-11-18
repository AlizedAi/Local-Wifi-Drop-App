import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_wifi_drop/src/protocol_frame.dart';
import 'package:local_wifi_drop/src/receiver_protocol_guard.dart';
import 'package:local_wifi_drop/src/streaming_file_receiver.dart';
import 'package:local_wifi_drop/src/tcp_frame_connection.dart';
import 'package:local_wifi_drop/src/transfer_manifest.dart';

void main() {
  group('StreamingFileReceiver', () {
    Future<({TcpFrameConnection sender, TcpFrameConnection receiver, ServerSocket server})>
        openPair() async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = server.first.then(TcpFrameConnection.fromSocket);
      final sender = TcpFrameConnection.fromSocket(
        await Socket.connect(InternetAddress.loopbackIPv4, server.port),
      );
      return (sender: sender, receiver: await accepted, server: server);
    }

    ReceiverProtocolGuard approved(TransferManifest manifest) {
      return ReceiverProtocolGuard()
        ..markHelloAuthenticated()
        ..receiveManifest(manifest)
        ..approve();
    }

    ProtocolFrame begin(int index, int size) {
      final bytes = Uint8List(12);
      final data = ByteData.sublistView(bytes);
      data.setUint32(0, index, Endian.big);
      data.setUint64(4, size, Endian.big);
      return ProtocolFrame(ProtocolMessageType.fileBegin, bytes);
    }

    ProtocolFrame dataFrame(int index, int offset, List<int> bytes) {
      return ProtocolFrame(
        ProtocolMessageType.fileData,
        FileDataChunk(fileIndex: index, offset: offset, data: bytes).encodePayload(),
      );
    }

    ProtocolFrame endFrame(int index, List<int> digest) {
      return ProtocolFrame(
        ProtocolMessageType.fileEnd,
        FileEndPayload(fileIndex: index, digest: digest).encodePayload(),
      );
    }

    test('streams, verifies and finalizes a multi-chunk file', () async {
      final directory = await Directory.systemTemp.createTemp('wifi-drop-recv-');
      final bytes = List<int>.generate(FileDataChunk.maxDataBytes + 19, (i) => i & 255);
      final manifest = TransferManifest(
        batchId: List<int>.filled(16, 21),
        files: [TransferFileEntry(name: 'large.bin', size: bytes.length)],
      );
      final pair = await openPair();
      final guard = approved(manifest);
      final receive = const StreamingFileReceiver().receiveBatch(
        connection: pair.receiver,
        manifest: manifest,
        guard: guard,
        destinationDirectory: directory,
      );

      await pair.sender.sendFrame(begin(0, bytes.length));
      var offset = 0;
      while (offset < bytes.length) {
        final end = (offset + FileDataChunk.maxDataBytes).clamp(0, bytes.length);
        await pair.sender.sendFrame(dataFrame(0, offset, bytes.sublist(offset, end)));
        offset = end;
      }
      await pair.sender.sendFrame(endFrame(0, sha256.convert(bytes).bytes));
      await pair.sender.sendFrame(ProtocolFrame(ProtocolMessageType.batchDone, const []));

      final result = await receive;
      expect(result.cancelled, isFalse);
      expect(result.files, hasLength(1));
      expect(await result.files.single.readAsBytes(), bytes);
      expect(guard.phase, ReceiverProtocolPhase.completed);
      expect(await directory.list().length, 1);

      await pair.sender.close();
      await pair.receiver.close();
      await pair.server.close();
      await directory.delete(recursive: true);
    });

    test('deletes temporary data when digest verification fails', () async {
      final directory = await Directory.systemTemp.createTemp('wifi-drop-bad-digest-');
      final manifest = TransferManifest(
        batchId: List<int>.filled(16, 22),
        files: [TransferFileEntry(name: 'bad.bin', size: 3)],
      );
      final pair = await openPair();
      final guard = approved(manifest);
      final receive = const StreamingFileReceiver().receiveBatch(
        connection: pair.receiver,
        manifest: manifest,
        guard: guard,
        destinationDirectory: directory,
      );

      await pair.sender.sendFrame(begin(0, 3));
      await pair.sender.sendFrame(dataFrame(0, 0, [1, 2, 3]));
      await pair.sender.sendFrame(endFrame(0, List<int>.filled(32, 0)));

      await expectLater(receive, throwsFormatException);
      expect(guard.phase, ReceiverProtocolPhase.failed);
      expect(await directory.list().toList(), isEmpty);

      await pair.sender.close();
      await pair.receiver.close();
      await pair.server.close();
      await directory.delete(recursive: true);
    });

    test('cancel removes the active partial file and preserves completed files', () async {
      final directory = await Directory.systemTemp.createTemp('wifi-drop-cancel-');
      final manifest = TransferManifest(
        batchId: List<int>.filled(16, 23),
        files: [TransferFileEntry(name: 'partial.bin', size: 100)],
      );
      final pair = await openPair();
      final guard = approved(manifest);
      final receive = const StreamingFileReceiver().receiveBatch(
        connection: pair.receiver,
        manifest: manifest,
        guard: guard,
        destinationDirectory: directory,
      );

      await pair.sender.sendFrame(begin(0, 100));
      await pair.sender.sendFrame(dataFrame(0, 0, [1, 2, 3]));
      await pair.sender.sendFrame(ProtocolFrame(ProtocolMessageType.cancel, const []));

      final result = await receive;
      expect(result.cancelled, isTrue);
      expect(result.files, isEmpty);
      expect(guard.phase, ReceiverProtocolPhase.cancelled);
      expect(await directory.list().toList(), isEmpty);

      await pair.sender.close();
      await pair.receiver.close();
      await pair.server.close();
      await directory.delete(recursive: true);
    });

    test('does not overwrite an existing destination file', () async {
      final directory = await Directory.systemTemp.createTemp('wifi-drop-collision-');
      final existing = File('${directory.path}/same.txt');
      await existing.writeAsString('keep me');
      final bytes = [4, 5, 6];
      final manifest = TransferManifest(
        batchId: List<int>.filled(16, 24),
        files: [TransferFileEntry(name: 'same.txt', size: bytes.length)],
      );
      final pair = await openPair();
      final guard = approved(manifest);
      final receive = const StreamingFileReceiver().receiveBatch(
        connection: pair.receiver,
        manifest: manifest,
        guard: guard,
        destinationDirectory: directory,
      );

      await pair.sender.sendFrame(begin(0, bytes.length));
      await pair.sender.sendFrame(dataFrame(0, 0, bytes));
      await pair.sender.sendFrame(endFrame(0, sha256.convert(bytes).bytes));
      await pair.sender.sendFrame(ProtocolFrame(ProtocolMessageType.batchDone, const []));

      final result = await receive;
      expect(await existing.readAsString(), 'keep me');
      expect(result.files.single.path, '${directory.path}/same (1).txt');
      expect(await result.files.single.readAsBytes(), bytes);

      await pair.sender.close();
      await pair.receiver.close();
      await pair.server.close();
      await directory.delete(recursive: true);
    });
  });
}
