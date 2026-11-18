import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_wifi_drop/src/tcp_frame_connection.dart';
import 'package:local_wifi_drop/src/protocol_frame.dart';
import 'package:local_wifi_drop/src/tcp_transfer_session.dart';
import 'package:local_wifi_drop/src/transfer_alert.dart';
import 'package:local_wifi_drop/src/transfer_cancellation.dart';
import 'package:local_wifi_drop/src/transfer_manifest.dart';

void main() {
  group('TcpTransferSession', () {
    Future<({TcpFrameConnection sender, TcpFrameConnection receiver, ServerSocket server})>
        openPair() async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = server.first.then(TcpFrameConnection.fromSocket);
      final sender = TcpFrameConnection.fromSocket(
        await Socket.connect(InternetAddress.loopbackIPv4, server.port),
      );
      return (sender: sender, receiver: await accepted, server: server);
    }

    test('keeps one connection open for two-way chat messages', () async {
      final pair = await openPair();

      await pair.sender.sendFrame(ProtocolFrame(
        ProtocolMessageType.textMessage,
        TextMessagePayload('Hello').bytes,
      ));
      final first = await pair.receiver.readFrame();
      expect(first?.type, ProtocolMessageType.textMessage);
      expect(TextMessagePayload.decode(first!.payload).text, 'Hello');

      await pair.receiver.sendFrame(ProtocolFrame(
        ProtocolMessageType.textMessage,
        TextMessagePayload('Hi back').bytes,
      ));
      final reply = await pair.sender.readFrame();
      expect(reply?.type, ProtocolMessageType.textMessage);
      expect(TextMessagePayload.decode(reply!.payload).text, 'Hi back');

      await pair.sender.sendFrame(ProtocolFrame(
        ProtocolMessageType.textMessage,
        TextMessagePayload('How are you?').bytes,
      ));
      final followUp = await pair.receiver.readFrame();
      expect(TextMessagePayload.decode(followUp!.payload).text, 'How are you?');

      await pair.sender.close();
      await pair.receiver.close();
      await pair.server.close();
    });

    test('sends a standalone text message and waits for receiver approval', () async {
      final pair = await openPair();
      const message = 'Hello from Local WiFi Drop 👋\nسلام';
      var approvedMessage = '';

      final receiving = () async {
        final frame = await pair.receiver.readFrame();
        if (frame == null) throw StateError('No message frame received');
        return const TcpTransferSession().receiveTextMessage(
          connection: pair.receiver,
          initialFrame: frame,
          approve: (incoming) async {
            approvedMessage = incoming;
            return true;
          },
        );
      }();
      final sending = const TcpTransferSession().sendTextMessage(
        connection: pair.sender,
        text: message,
      );

      expect(await sending, TextMessageOutcome.accepted);
      expect(await receiving, message);
      expect(approvedMessage, message);

      await pair.server.close();
    });

    test('reports receiver rejection for a standalone text message', () async {
      final pair = await openPair();
      final receiving = () async {
        final frame = await pair.receiver.readFrame();
        if (frame == null) throw StateError('No message frame received');
        return const TcpTransferSession().receiveTextMessage(
          connection: pair.receiver,
          initialFrame: frame,
          approve: (_) async => false,
        );
      }();
      final sending = const TcpTransferSession().sendTextMessage(
        connection: pair.sender,
        text: 'Please reject this',
      );

      final rejected = expectLater(receiving, throwsFormatException);
      expect(await sending, TextMessageOutcome.rejected);
      await rejected;

      await pair.server.close();
    });

    test('completes an approved disk-to-disk transfer and reports sent files', () async {
      final source = await Directory.systemTemp.createTemp('wifi-drop-session-src-');
      final destination = await Directory.systemTemp.createTemp('wifi-drop-session-dst-');
      final firstBytes = List<int>.generate(70 * 1024 + 17, (i) => i & 255);
      final secondBytes = [9, 8, 7, 6, 5];
      final first = File('${source.path}/first.bin');
      final second = File('${source.path}/second.txt');
      await first.writeAsBytes(firstBytes, flush: true);
      await second.writeAsBytes(secondBytes, flush: true);

      final manifest = TransferManifest(
        batchId: List<int>.filled(16, 41),
        files: [
          TransferFileEntry(name: 'first.bin', size: firstBytes.length),
          TransferFileEntry(name: 'second.txt', size: secondBytes.length),
        ],
      );
      final pair = await openPair();
      final alerts = <TransferAlert>[];
      final senderProgress = <int>[];
      var finalStorageComplete = false;
      final receiving = const TcpTransferSession().receiveBatch(
        connection: pair.receiver,
        destinationDirectory: destination,
        approve: (incoming) async {
          expect(incoming.files, hasLength(2));
          return true;
        },
        finalizeFiles: (files) async {
          expect(files, hasLength(2));
          finalStorageComplete = true;
        },
      );
      final sending = const TcpTransferSession().sendBatch(
        connection: pair.sender,
        manifest: manifest,
        files: [first, second],
        onAlert: alerts.add,
        onProgress: (sent, total) {
          expect(total, firstBytes.length + secondBytes.length);
          senderProgress.add(sent);
        },
      );

      expect(await sending, SenderSessionOutcome.completed);
      expect(finalStorageComplete, isTrue);
      final received = await receiving;
      expect(received.outcome, ReceiverSessionOutcome.completed);
      expect(received.files, hasLength(2));
      expect(await received.files[0].readAsBytes(), firstBytes);
      expect(await received.files[1].readAsBytes(), secondBytes);
      expect(senderProgress, isNotEmpty);
      expect(senderProgress.last, firstBytes.length + secondBytes.length);
      expect(senderProgress, orderedEquals([...senderProgress]..sort()));
      expect(alerts.map((alert) => alert.displayText), [
        'first.bin      sent',
        'second.txt      sent',
      ]);

      await pair.server.close();
      await source.delete(recursive: true);
      await destination.delete(recursive: true);
    });

    test('cancelling during a file closes socket, cleans partial data and logs cancelled alerts', () async {
      final source = await Directory.systemTemp.createTemp('wifi-drop-cancel-src-');
      final destination = await Directory.systemTemp.createTemp('wifi-drop-cancel-dst-');
      final first = File('${source.path}/A.MP3');
      final second = File('${source.path}/B.MP3');
      await first.writeAsBytes(List<int>.filled(4 * 1024 * 1024, 17), flush: true);
      await second.writeAsBytes([1, 2, 3], flush: true);
      final manifest = TransferManifest(
        batchId: List<int>.filled(16, 43),
        files: [
          TransferFileEntry(name: 'A.MP3', size: await first.length()),
          TransferFileEntry(name: 'B.MP3', size: await second.length()),
        ],
      );
      final pair = await openPair();
      final cancellation = TransferCancellation();
      final alerts = <TransferAlert>[];
      var cancelTriggered = false;
      final receiving = const TcpTransferSession().receiveBatch(
        connection: pair.receiver,
        destinationDirectory: destination,
        approve: (_) async => true,
        onProgress: (received, total) {
          if (!cancelTriggered && received > 0) {
            cancelTriggered = true;
            cancellation.cancel();
          }
        },
      );
      final sending = const TcpTransferSession().sendBatch(
        connection: pair.sender,
        manifest: manifest,
        files: [first, second],
        cancellation: cancellation,
        onAlert: alerts.add,
      );

      expect(await sending, SenderSessionOutcome.cancelled);
      await expectLater(
        receiving,
        throwsA(anyOf(isA<SocketException>(), isA<FormatException>())),
      );
      expect(cancelTriggered, isTrue);
      expect(alerts.map((alert) => alert.displayText), [
        'A.MP3      cancelled',
        'B.MP3      cancelled',
      ]);
      expect(await destination.list().toList(), isEmpty);

      await pair.server.close();
      await source.delete(recursive: true);
      await destination.delete(recursive: true);
    });

    test('sender cancellation preserves already sent files and marks only remaining files cancelled', () async {
      final source = await Directory.systemTemp.createTemp('wifi-drop-sent-cancel-src-');
      final destination = await Directory.systemTemp.createTemp('wifi-drop-sent-cancel-dst-');
      final firstBytes = [1, 2, 3, 4, 5];
      final secondBytes = List<int>.filled(2 * 1024 * 1024, 11);
      final first = File('${source.path}/already-sent.txt');
      final second = File('${source.path}/next-file.bin');
      await first.writeAsBytes(firstBytes, flush: true);
      await second.writeAsBytes(secondBytes, flush: true);
      final manifest = TransferManifest(
        batchId: List<int>.filled(16, 53),
        files: [
          TransferFileEntry(name: 'already-sent.txt', size: firstBytes.length),
          TransferFileEntry(name: 'next-file.bin', size: secondBytes.length),
        ],
      );
      final pair = await openPair();
      final cancellation = TransferCancellation();
      final alerts = <TransferAlert>[];
      var cancelTriggered = false;
      final receiving = const TcpTransferSession().receiveBatch(
        connection: pair.receiver,
        destinationDirectory: destination,
        approve: (_) async => true,
      );
      final sending = const TcpTransferSession().sendBatch(
        connection: pair.sender,
        manifest: manifest,
        files: [first, second],
        cancellation: cancellation,
        onAlert: alerts.add,
        onProgress: (sentBytes, totalBytes) {
          if (!cancelTriggered && sentBytes > firstBytes.length) {
            cancelTriggered = true;
            cancellation.cancel();
          }
        },
      );
      final receivingSettled = receiving.then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {
          if (error is! SocketException) {
            Error.throwWithStackTrace(error, stack);
          }
        },
      );

      expect(await sending, SenderSessionOutcome.cancelled);
      await receivingSettled;
      expect(alerts.map((alert) => alert.displayText), [
        'already-sent.txt      cancelled',
        'next-file.bin      cancelled',
      ]);
      final saved = await destination.list().toList();
      expect(saved, hasLength(1));
      expect(saved.single.path, File('${destination.path}${Platform.pathSeparator}already-sent.txt').path);
      expect(await File(saved.single.path).readAsBytes(), firstBytes);

      await pair.server.close();
      await source.delete(recursive: true);
      await destination.delete(recursive: true);
    });

    test('receiver cancellation preserves completed files and reports remaining files', () async {
      final source = await Directory.systemTemp.createTemp('wifi-drop-receiver-cancel-src-');
      final destination = await Directory.systemTemp.createTemp('wifi-drop-receiver-cancel-dst-');
      final firstBytes = [1, 2, 3, 4];
      final secondBytes = List<int>.filled(1024 * 1024, 9);
      final first = File('${source.path}/done.txt');
      final second = File('${source.path}/active.bin');
      await first.writeAsBytes(firstBytes, flush: true);
      await second.writeAsBytes(secondBytes, flush: true);
      final manifest = TransferManifest(
        batchId: List<int>.filled(16, 47),
        files: [
          TransferFileEntry(name: 'done.txt', size: firstBytes.length),
          TransferFileEntry(name: 'active.bin', size: secondBytes.length),
        ],
      );
      final pair = await openPair();
      final cancellation = TransferCancellation();
      final alerts = <TransferAlert>[];
      var cancelTriggered = false;
      final receiving = const TcpTransferSession().receiveBatch(
        connection: pair.receiver,
        destinationDirectory: destination,
        approve: (_) async => true,
        cancellation: cancellation,
        onProgress: (received, total) {
          if (!cancelTriggered && received > firstBytes.length) {
            cancelTriggered = true;
            cancellation.cancel();
          }
        },
        onAlert: alerts.add,
      );
      final sending = const TcpTransferSession().sendBatch(
        connection: pair.sender,
        manifest: manifest,
        files: [first, second],
      );
      final sendingSettled = sending.then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {
          if (error is! SocketException) {
            Error.throwWithStackTrace(error, stack);
          }
        },
      );

      final received = await receiving;
      expect(received.outcome, ReceiverSessionOutcome.cancelled);
      expect(received.files, hasLength(1));
      expect(await received.files.single.readAsBytes(), firstBytes);
      expect(cancelTriggered, isTrue);
      expect(alerts.map((alert) => alert.displayText), [
        'active.bin      cancelled',
      ]);
      final saved = await destination.list().toList();
      expect(saved, hasLength(1));
      expect(saved.single.path, File('${destination.path}${Platform.pathSeparator}done.txt').path);
      await sendingSettled;

      await pair.server.close();
      await source.delete(recursive: true);
      await destination.delete(recursive: true);
    });

    test('reports failed files on sender and receiver I/O errors', () async {
      final source = await Directory.systemTemp.createTemp('wifi-drop-failed-src-');
      final destination = await Directory.systemTemp.createTemp('wifi-drop-failed-dst-');
      final file = File('${source.path}/changed.bin');
      await file.writeAsBytes([1, 2, 3, 4], flush: true);
      final manifest = TransferManifest(
        batchId: List<int>.filled(16, 49),
        files: [TransferFileEntry(name: 'changed.bin', size: 3)],
      );
      final pair = await openPair();
      final senderAlerts = <TransferAlert>[];
      final receiverAlerts = <TransferAlert>[];
      final receiving = const TcpTransferSession().receiveBatch(
        connection: pair.receiver,
        destinationDirectory: destination,
        approve: (_) async => true,
        onAlert: receiverAlerts.add,
      );
      final sending = const TcpTransferSession().sendBatch(
        connection: pair.sender,
        manifest: manifest,
        files: [file],
        onAlert: senderAlerts.add,
      );
      final sendingExpectation = expectLater(
        sending,
        throwsA(isA<FileSystemException>()),
      );
      final receivingExpectation = expectLater(
        receiving,
        throwsA(isA<SocketException>()),
      );

      await sendingExpectation;
      await receivingExpectation;
      expect(senderAlerts.map((alert) => alert.displayText), [
        'changed.bin      failed',
      ]);
      expect(receiverAlerts.map((alert) => alert.displayText), [
        'changed.bin      failed',
      ]);
      expect(await destination.list().toList(), isEmpty);

      await pair.server.close();
      await source.delete(recursive: true);
      await destination.delete(recursive: true);
    });

    test('rejection closes the session before any file is written', () async {
      final source = await Directory.systemTemp.createTemp('wifi-drop-reject-src-');
      final destination = await Directory.systemTemp.createTemp('wifi-drop-reject-dst-');
      final file = File('${source.path}/private.txt');
      await file.writeAsString('must not be sent');
      final manifest = TransferManifest(
        batchId: List<int>.filled(16, 42),
        files: [TransferFileEntry(name: 'private.txt', size: await file.length())],
      );
      final pair = await openPair();
      final senderAlerts = <TransferAlert>[];
      final receiverAlerts = <TransferAlert>[];

      final receiving = const TcpTransferSession().receiveBatch(
        connection: pair.receiver,
        destinationDirectory: destination,
        approve: (_) async => false,
        onAlert: receiverAlerts.add,
      );
      final sending = const TcpTransferSession().sendBatch(
        connection: pair.sender,
        manifest: manifest,
        files: [file],
        onAlert: senderAlerts.add,
      );

      expect(await sending, SenderSessionOutcome.rejected);
      final received = await receiving;
      expect(received.outcome, ReceiverSessionOutcome.rejected);
      expect(received.files, isEmpty);
      expect(senderAlerts.map((alert) => alert.displayText), [
        'private.txt      rejected',
      ]);
      expect(receiverAlerts.map((alert) => alert.displayText), [
        'private.txt      rejected',
      ]);
      expect(await destination.list().toList(), isEmpty);

      await pair.server.close();
      await source.delete(recursive: true);
      await destination.delete(recursive: true);
    });
  });
}
