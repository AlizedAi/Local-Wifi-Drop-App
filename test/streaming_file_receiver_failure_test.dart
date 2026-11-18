import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_wifi_drop/src/protocol_frame.dart';
import 'package:local_wifi_drop/src/receiver_protocol_guard.dart';
import 'package:local_wifi_drop/src/streaming_file_receiver.dart';
import 'package:local_wifi_drop/src/tcp_frame_connection.dart';
import 'package:local_wifi_drop/src/transfer_manifest.dart';

void main() {
  group('StreamingFileReceiver failure cleanup', () {
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

    ProtocolFrame begin(int size) {
      final payload = Uint8List(12);
      final data = ByteData.sublistView(payload);
      data.setUint32(0, 0, Endian.big);
      data.setUint64(4, size, Endian.big);
      return ProtocolFrame(ProtocolMessageType.fileBegin, payload);
    }

    ProtocolFrame dataFrame(List<int> bytes) {
      return ProtocolFrame(
        ProtocolMessageType.fileData,
        FileDataChunk(fileIndex: 0, offset: 0, data: bytes).encodePayload(),
      );
    }

    test('removes partial file when sender disconnects mid-file', () async {
      final directory = await Directory.systemTemp.createTemp('wifi-drop-disconnect-');
      final manifest = TransferManifest(
        batchId: List<int>.filled(16, 31),
        files: [TransferFileEntry(name: 'partial.bin', size: 100)],
      );
      final pair = await openPair();
      final guard = approved(manifest);
      final receiving = const StreamingFileReceiver().receiveBatch(
        connection: pair.receiver,
        manifest: manifest,
        guard: guard,
        destinationDirectory: directory,
      );

      await pair.sender.sendFrame(begin(100));
      await pair.sender.sendFrame(dataFrame([1, 2, 3, 4]));
      await pair.sender.close();

      await expectLater(receiving, throwsA(isA<SocketException>()));
      expect(guard.phase, ReceiverProtocolPhase.failed);
      expect(await directory.list().toList(), isEmpty);

      await pair.receiver.close();
      await pair.server.close();
      await directory.delete(recursive: true);
    });

    test('removes partial file after the receiver idle timeout', () async {
      final directory = await Directory.systemTemp.createTemp('wifi-drop-idle-timeout-');
      final manifest = TransferManifest(
        batchId: List<int>.filled(16, 33),
        files: [TransferFileEntry(name: 'idle.bin', size: 100)],
      );
      final pair = await openPair();
      final guard = approved(manifest);
      final receiving = const StreamingFileReceiver().receiveBatch(
        connection: pair.receiver,
        manifest: manifest,
        guard: guard,
        destinationDirectory: directory,
        idleTimeout: const Duration(milliseconds: 50),
      );

      await pair.sender.sendFrame(begin(100));
      await pair.sender.sendFrame(dataFrame([1, 2, 3]));

      await expectLater(receiving, throwsA(isA<TimeoutException>()));
      expect(guard.phase, ReceiverProtocolPhase.failed);
      expect(await directory.list().toList(), isEmpty);

      await pair.sender.close();
      await pair.receiver.close();
      await pair.server.close();
      await directory.delete(recursive: true);
    });

    test('removes partial file when FILE_END payload is malformed', () async {
      final directory = await Directory.systemTemp.createTemp('wifi-drop-malformed-end-');
      final manifest = TransferManifest(
        batchId: List<int>.filled(16, 32),
        files: [TransferFileEntry(name: 'partial.bin', size: 3)],
      );
      final pair = await openPair();
      final guard = approved(manifest);
      final receiving = const StreamingFileReceiver().receiveBatch(
        connection: pair.receiver,
        manifest: manifest,
        guard: guard,
        destinationDirectory: directory,
      );

      await pair.sender.sendFrame(begin(3));
      await pair.sender.sendFrame(dataFrame([7, 8, 9]));
      await pair.sender.sendFrame(
        ProtocolFrame(ProtocolMessageType.fileEnd, const [0, 0, 0]),
      );

      await expectLater(receiving, throwsFormatException);
      expect(guard.phase, ReceiverProtocolPhase.failed);
      expect(await directory.list().toList(), isEmpty);

      await pair.sender.close();
      await pair.receiver.close();
      await pair.server.close();
      await directory.delete(recursive: true);
    });
  });
}
