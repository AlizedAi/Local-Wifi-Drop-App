import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_wifi_drop/src/hello_payload.dart';
import 'package:local_wifi_drop/src/pairing_credentials.dart';
import 'package:local_wifi_drop/src/pairing_session_authenticator.dart';
import 'package:local_wifi_drop/src/protocol_frame.dart';
import 'package:local_wifi_drop/src/tcp_frame_connection.dart';
import 'package:local_wifi_drop/src/tcp_transfer_server.dart';
import 'package:local_wifi_drop/src/tcp_transfer_handshake.dart';
import 'package:local_wifi_drop/src/sender_protocol_guard.dart';
import 'package:local_wifi_drop/src/receiver_protocol_guard.dart';
import 'package:local_wifi_drop/src/transfer_manifest.dart';
import 'package:local_wifi_drop/src/streaming_file_sender.dart';

void main() {
  group('TCP frame transport', () {
    test('authenticates HELLO and exchanges frames over loopback', () async {
      final server = await TcpTransferServer.bind(address: InternetAddress.loopbackIPv4);
      final credentials = PairingCredentials.generate();
      final auth = PairingSessionAuthenticator(
        credentials: credentials,
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 1)),
      );
      final accepted = server.acceptAuthenticated(authenticator: auth);
      final sender = TcpFrameConnection.fromSocket(
        await Socket.connect(InternetAddress.loopbackIPv4, server.port),
      );
      final hello = HelloPayload.fromEncodedCredentials(
        sessionId: credentials.sessionId, token: credentials.token,
      );
      await sender.sendFrame(ProtocolFrame(ProtocolMessageType.hello, hello.encode()));
      final receiver = await accepted;
      await sender.sendFrame(ProtocolFrame(ProtocolMessageType.manifest, [1, 2, 3]));
      final frame = await receiver.readFrame();
      expect(frame?.type, ProtocolMessageType.manifest);
      expect(frame?.payload, [1, 2, 3]);
      expect(auth.isConsumed, isTrue);
      await sender.close();
      await receiver.close();
      await server.close();
    });

    test('chat message receives an acknowledgement for its message ID', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final receiverFuture = server.first.then(TcpFrameConnection.fromSocket);
      final sender = TcpFrameConnection.fromSocket(
        await Socket.connect(InternetAddress.loopbackIPv4, server.port),
      );
      final receiver = await receiverFuture;
      final message = ChatMessagePayload(messageId: 17, text: 'hello');
      await sender.sendFrame(ProtocolFrame(ProtocolMessageType.chatMessage, message.bytes));
      final received = await receiver.readFrame();
      expect(received?.type, ProtocolMessageType.chatMessage);
      final decoded = ChatMessagePayload.decode(received!.payload);
      expect(decoded.messageId, 17);
      expect(decoded.text, 'hello');
      await receiver.sendFrame(ProtocolFrame(
        ProtocolMessageType.chatAck,
        ChatMessageAckPayload(messageId: decoded.messageId).bytes,
      ));
      final acknowledgement = await sender.readFrame();
      expect(acknowledgement?.type, ProtocolMessageType.chatAck);
      expect(ChatMessageAckPayload.decode(acknowledgement!.payload).messageId, 17);
      await sender.close();
      await receiver.close();
      await server.close();
    });

    test('rejects wrong one-time token', () async {
      final server = await TcpTransferServer.bind(address: InternetAddress.loopbackIPv4);
      final credentials = PairingCredentials.generate();
      final wrong = PairingCredentials.generate();
      final auth = PairingSessionAuthenticator(
        credentials: credentials,
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 1)),
      );
      final accepted = server.acceptAuthenticated(authenticator: auth);
      final rejection = expectLater(accepted, throwsFormatException);
      final sender = TcpFrameConnection.fromSocket(
        await Socket.connect(InternetAddress.loopbackIPv4, server.port),
      );
      final hello = HelloPayload.fromEncodedCredentials(
        sessionId: credentials.sessionId, token: wrong.token,
      );
      await sender.sendFrame(ProtocolFrame(ProtocolMessageType.hello, hello.encode()));
      await rejection;
      expect(auth.isConsumed, isFalse);
      await sender.close();
      await server.close();
    });


    test('rejects a peer that sends a non-HELLO first frame', () async {
      final server = await TcpTransferServer.bind(address: InternetAddress.loopbackIPv4);
      final credentials = PairingCredentials.generate();
      final auth = PairingSessionAuthenticator(
        credentials: credentials,
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 1)),
      );
      final accepted = server.acceptAuthenticated(
        authenticator: auth,
        timeout: const Duration(seconds: 1),
      );
      final rejection = expectLater(accepted, throwsFormatException);
      final sender = TcpFrameConnection.fromSocket(
        await Socket.connect(InternetAddress.loopbackIPv4, server.port),
      );

      await sender.sendFrame(
        ProtocolFrame(ProtocolMessageType.manifest, [1, 2, 3]),
      );

      await rejection;
      expect(server.isClosed, isTrue);
      await sender.close();
    });

    test('closes listener when no peer connects before timeout', () async {
      final server = await TcpTransferServer.bind(address: InternetAddress.loopbackIPv4);
      final auth = PairingSessionAuthenticator(
        credentials: PairingCredentials.generate(),
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 1)),
      );

      await expectLater(
        server.acceptAuthenticated(
          authenticator: auth,
          timeout: const Duration(milliseconds: 20),
        ),
        throwsA(isA<TimeoutException>()),
      );

      expect(server.isClosed, isTrue);
    });


    test('receiver approval is required before sender proceeds', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final acceptedFuture = server.first.then(TcpFrameConnection.fromSocket);
      final sender = TcpFrameConnection.fromSocket(
        await Socket.connect(InternetAddress.loopbackIPv4, server.port),
      );
      final receiver = await acceptedFuture;
      final manifest = TransferManifest(
        batchId: List<int>.filled(16, 1),
        files: [
          TransferFileEntry(name: 'hello.txt', size: 0),
        ],
      );

      final receiverDecision = TcpReceiverHandshake.receiveManifestAndRequestApproval(
        connection: receiver,
        approve: (received) async {
          expect(received.files.single.name, 'hello.txt');
          return true;
        },
      );
      final accepted = await TcpSenderHandshake.sendManifestAndAwaitDecision(
        connection: sender,
        manifest: manifest,
      );

      expect(await receiverDecision, isTrue);
      expect(accepted, isTrue);
      await sender.close();
      await receiver.close();
      await server.close();
    });

    test('receiver rejection stops sender before any file frame', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final acceptedFuture = server.first.then(TcpFrameConnection.fromSocket);
      final sender = TcpFrameConnection.fromSocket(
        await Socket.connect(InternetAddress.loopbackIPv4, server.port),
      );
      final receiver = await acceptedFuture;
      final manifest = TransferManifest(
        batchId: List<int>.filled(16, 2),
        files: [
          TransferFileEntry(name: 'private.txt', size: 10),
        ],
      );

      final receiverDecision = TcpReceiverHandshake.receiveManifestAndRequestApproval(
        connection: receiver,
        approve: (_) async => false,
      );
      final accepted = await TcpSenderHandshake.sendManifestAndAwaitDecision(
        connection: sender,
        manifest: manifest,
      );

      expect(await receiverDecision, isFalse);
      expect(accepted, isFalse);
      await sender.close();
      await receiver.close();
      await server.close();
    });

    test('connected peers enforce ordered file frames and cancellation', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final receiverFuture = server.first.then(TcpFrameConnection.fromSocket);
      final sender = TcpFrameConnection.fromSocket(
        await Socket.connect(InternetAddress.loopbackIPv4, server.port),
      );
      final receiver = await receiverFuture;
      final manifest = TransferManifest(
        batchId: List<int>.filled(16, 8),
        files: [TransferFileEntry(name: 'payload.bin', size: 3)],
      );

      final receiverGuard = ReceiverProtocolGuard()..markHelloAuthenticated();
      final approval = TcpReceiverHandshake.receiveManifestAndRequestApproval(
        connection: receiver,
        approve: (received) async {
          receiverGuard.receiveManifest(received);
          receiverGuard.approve();
          return true;
        },
      );
      final senderGuard = SenderProtocolGuard(manifest: manifest);
      final accepted = await TcpSenderHandshake.sendManifestAndAwaitDecision(
        connection: sender,
        manifest: manifest,
      );
      expect(await approval, isTrue);
      expect(accepted, isTrue);
      senderGuard.receiveDecision(ProtocolFrame(ProtocolMessageType.accept, []));

      final beginPayload = Uint8List(12);
      final beginData = ByteData.sublistView(beginPayload);
      beginData.setUint32(0, 0, Endian.big);
      beginData.setUint64(4, 3, Endian.big);
      final begin = ProtocolFrame(ProtocolMessageType.fileBegin, beginPayload);
      senderGuard.authorizeOutbound(begin);
      await sender.sendFrame(begin);
      receiverGuard.receiveFrame((await receiver.readFrame())!);

      final chunk = ProtocolFrame(
        ProtocolMessageType.fileData,
        FileDataChunk(fileIndex: 0, offset: 0, data: [4, 5, 6]).encodePayload(),
      );
      senderGuard.authorizeOutbound(chunk);
      await sender.sendFrame(chunk);
      receiverGuard.receiveFrame((await receiver.readFrame())!);

      final end = ProtocolFrame(
        ProtocolMessageType.fileEnd,
        FileEndPayload(fileIndex: 0, digest: List<int>.filled(32, 7)).encodePayload(),
      );
      senderGuard.authorizeOutbound(end);
      await sender.sendFrame(end);
      receiverGuard.receiveFrame((await receiver.readFrame())!);

      final cancel = ProtocolFrame(ProtocolMessageType.cancel, []);
      senderGuard.authorizeOutbound(cancel);
      await sender.sendFrame(cancel);
      receiverGuard.receiveFrame((await receiver.readFrame())!);

      expect(senderGuard.phase, SenderProtocolPhase.cancelled);
      expect(receiverGuard.phase, ReceiverProtocolPhase.cancelled);
      await sender.close();
      await receiver.close();
      await server.close();
    });

    test('streams disk files in bounded chunks and sends matching digest', () async {
      final directory = await Directory.systemTemp.createTemp('wifi-drop-send-');
      final file = File('${directory.path}/sample.bin');
      final contents = List<int>.generate(
        FileDataChunk.maxDataBytes + 37,
        (index) => index & 0xff,
      );
      await file.writeAsBytes(contents, flush: true);

      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final receiverFuture = server.first.then(TcpFrameConnection.fromSocket);
      final sender = TcpFrameConnection.fromSocket(
        await Socket.connect(InternetAddress.loopbackIPv4, server.port),
      );
      final receiver = await receiverFuture;
      final manifest = TransferManifest(
        batchId: List<int>.filled(16, 11),
        files: [TransferFileEntry(name: 'sample.bin', size: contents.length)],
      );
      final guard = SenderProtocolGuard(manifest: manifest)
        ..receiveDecision(ProtocolFrame(ProtocolMessageType.accept, const []));

      final sending = const StreamingFileSender().sendBatch(
        connection: sender,
        manifest: manifest,
        guard: guard,
        files: [file],
      );

      final begin = await receiver.readFrame();
      expect(begin?.type, ProtocolMessageType.fileBegin);
      final received = <int>[];
      ProtocolFrame? end;
      while (end == null) {
        final frame = await receiver.readFrame();
        expect(frame, isNotNull);
        if (frame!.type == ProtocolMessageType.fileData) {
          final chunk = FileDataChunk.decodePayload(frame.payload);
          expect(chunk.offset, received.length);
          expect(chunk.data.length, lessThanOrEqualTo(FileDataChunk.maxDataBytes));
          received.addAll(chunk.data);
        } else if (frame.type == ProtocolMessageType.fileEnd) {
          end = frame;
        } else {
          fail('Unexpected frame: ${frame.type}');
        }
      }
      final endPayload = FileEndPayload.decodePayload(end.payload);
      expect(endPayload.fileIndex, 0);
      expect(endPayload.digest, sha256.convert(contents).bytes);
      expect(received, contents);

      final done = await receiver.readFrame();
      expect(done?.type, ProtocolMessageType.batchDone);
      await sending;
      expect(guard.phase, SenderProtocolPhase.completed);

      await sender.close();
      await receiver.close();
      await server.close();
      await directory.delete(recursive: true);
    });

    test('rejects a source file whose size changed after manifest creation', () async {
      final directory = await Directory.systemTemp.createTemp('wifi-drop-size-');
      final file = File('${directory.path}/changed.bin');
      await file.writeAsBytes([1, 2, 3], flush: true);
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final receiverFuture = server.first.then(TcpFrameConnection.fromSocket);
      final sender = TcpFrameConnection.fromSocket(
        await Socket.connect(InternetAddress.loopbackIPv4, server.port),
      );
      final receiver = await receiverFuture;
      final manifest = TransferManifest(
        batchId: List<int>.filled(16, 12),
        files: [TransferFileEntry(name: 'changed.bin', size: 2)],
      );
      final guard = SenderProtocolGuard(manifest: manifest)
        ..receiveDecision(ProtocolFrame(ProtocolMessageType.accept, const []));

      await expectLater(
        const StreamingFileSender().sendBatch(
          connection: sender,
          manifest: manifest,
          guard: guard,
          files: [file],
        ),
        throwsA(isA<FileSystemException>()),
      );

      expect(guard.phase, SenderProtocolPhase.transferring);
      await sender.close();
      await receiver.close();
      await server.close();
      await directory.delete(recursive: true);
    });

    test('returns null when peer closes at a frame boundary', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final acceptedSocket = server.first;
      final sender = await Socket.connect(InternetAddress.loopbackIPv4, server.port);
      final receiver = TcpFrameConnection.fromSocket(await acceptedSocket);

      await sender.close();

      expect(await receiver.readFrame(), isNull);

      await receiver.close();
      await server.close();
    });

    test('rejects a peer that closes during a frame header', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final acceptedSocket = server.first;
      final sender = await Socket.connect(InternetAddress.loopbackIPv4, server.port);
      final receiver = TcpFrameConnection.fromSocket(await acceptedSocket);

      sender.add([0, 0]);
      await sender.flush();
      await sender.close();

      await expectLater(receiver.readFrame(), throwsFormatException);

      await receiver.close();
      await server.close();
    });

    test('serializes concurrent frame writes without interleaving', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = server.first.then(TcpFrameConnection.fromSocket);
      final sender = TcpFrameConnection.fromSocket(
        await Socket.connect(InternetAddress.loopbackIPv4, server.port),
      );
      final receiver = await accepted;
      final writes = List<Future<void>>.generate(
        24,
        (index) => sender.sendFrame(
          ProtocolFrame(
            ProtocolMessageType.fileData,
            List<int>.filled(2048, index),
          ),
        ),
      );
      await Future.wait(writes);

      for (var index = 0; index < 24; index++) {
        final frame = await receiver.readFrame();
        expect(frame?.type, ProtocolMessageType.fileData);
        expect(frame?.payload, List<int>.filled(2048, index));
      }

      await sender.close();
      await receiver.close();
      await server.close();
    });

    test('preserves queued frames when multiple frames arrive together', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final acceptedSocket = server.first;
      final sender = await Socket.connect(InternetAddress.loopbackIPv4, server.port);
      final receiver = TcpFrameConnection.fromSocket(await acceptedSocket);

      final first = ProtocolFrame(ProtocolMessageType.accept, [7]).encode();
      final second = ProtocolFrame(ProtocolMessageType.cancel, []).encode();
      sender.add([...first, ...second]);
      await sender.flush();

      final firstReceived = await receiver.readFrame();
      final secondReceived = await receiver.readFrame();
      expect(firstReceived?.type, ProtocolMessageType.accept);
      expect(firstReceived?.payload, [7]);
      expect(secondReceived?.type, ProtocolMessageType.cancel);

      await sender.close();
      await receiver.close();
      await server.close();
    });
  });
}
