import 'dart:io';

import 'receiver_protocol_guard.dart';
import 'sender_protocol_guard.dart';
import 'streaming_file_receiver.dart';
import 'streaming_file_sender.dart';
import 'tcp_frame_connection.dart';
import 'tcp_transfer_handshake.dart';
import 'transfer_alert.dart';
import 'transfer_cancellation.dart';
import 'transfer_manifest.dart';
import 'protocol_frame.dart';

enum SenderSessionOutcome { completed, rejected, cancelled }

enum ReceiverSessionOutcome { completed, rejected, cancelled }
enum TextMessageOutcome { accepted, rejected }

class ReceiverSessionResult {
  const ReceiverSessionResult({
    required this.outcome,
    required this.files,
  });

  final ReceiverSessionOutcome outcome;
  final List<File> files;
}

class TcpTransferSession {
  const TcpTransferSession();


  Future<TextMessageOutcome> sendTextMessage({
    required TcpFrameConnection connection,
    required String text,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    try {
      final message = TextMessagePayload(text);
      await connection.sendFrame(
        ProtocolFrame(ProtocolMessageType.textMessage, message.bytes),
      );
      final decision = await connection.readFrame().timeout(timeout);
      if (decision == null || decision.payload.isNotEmpty) {
        throw const FormatException('Receiver did not return a valid message decision.');
      }
      if (decision.type == ProtocolMessageType.accept) {
        return TextMessageOutcome.accepted;
      }
      if (decision.type == ProtocolMessageType.reject) {
        return TextMessageOutcome.rejected;
      }
      throw const FormatException('Unexpected response to text message.');
    } finally {
      if (!connection.isClosed) await connection.close();
    }
  }

  Future<String> receiveTextMessage({
    required TcpFrameConnection connection,
    required ProtocolFrame initialFrame,
    required Future<bool> Function(String message) approve,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    try {
      if (initialFrame.type != ProtocolMessageType.textMessage) {
        throw const FormatException('Expected a text message.');
      }
      final message = TextMessagePayload.decode(initialFrame.payload).text;
      final accepted = await approve(message);
      await connection.sendFrame(ProtocolFrame(
        accepted ? ProtocolMessageType.accept : ProtocolMessageType.reject,
        const [],
      )).timeout(timeout);
      if (!accepted) throw const FormatException('Message was rejected by the receiver.');
      return message;
    } finally {
      if (!connection.isClosed) await connection.close();
    }
  }

  Future<SenderSessionOutcome> sendBatch({
    required TcpFrameConnection connection,
    required TransferManifest manifest,
    required List<File> files,
    Duration approvalTimeout = const Duration(seconds: 60),
    TransferCancellation? cancellation,
    void Function(TransferAlert alert)? onAlert,
    void Function(int sentBytes, int totalBytes)? onProgress,
    Duration writeTimeout = const Duration(seconds: 60),
  }) async {
    final guard = SenderProtocolGuard(manifest: manifest);
    final sent = List<bool>.filled(files.length, false);
    cancellation?.bind(() {
      if (guard.phase != SenderProtocolPhase.completed &&
          guard.phase != SenderProtocolPhase.rejected) {
        connection.destroy();
      }
    });
    try {
      final accepted = await TcpSenderHandshake.sendManifestAndAwaitDecision(
        connection: connection,
        manifest: manifest,
        guard: guard,
        timeout: approvalTimeout,
      );
      if (!accepted) {
        for (var index = 0; index < files.length; index++) {
          onAlert?.call(TransferAlert(
            fileName: manifest.files[index].name,
            status: TransferAlertStatus.rejected,
          ));
        }
        return SenderSessionOutcome.rejected;
      }

      await const StreamingFileSender().sendBatch(
        connection: connection,
        manifest: manifest,
        guard: guard,
        files: files,
        writeTimeout: writeTimeout,
        onProgress: onProgress,
        onFileSent: (_) {},
      );
      final acknowledgement = await connection.readFrame().timeout(const Duration(seconds: 60));
      if (acknowledgement == null ||
          acknowledgement.type != ProtocolMessageType.fileOk ||
          acknowledgement.payload.isNotEmpty) {
        throw const FormatException('Receiver did not confirm that every file was saved.');
      }
      for (var index = 0; index < files.length; index++) {
        sent[index] = true;
        onAlert?.call(TransferAlert(
          fileName: manifest.files[index].name,
          status: TransferAlertStatus.sent,
        ));
      }
      return SenderSessionOutcome.completed;
    } on Object {
      if (cancellation?.isCancelled == true) {
        guard.markCancelled();
        for (var index = 0; index < files.length; index++) {
          if (!sent[index]) {
            onAlert?.call(TransferAlert(
              fileName: manifest.files[index].name,
              status: TransferAlertStatus.cancelled,
            ));
          }
        }
        return SenderSessionOutcome.cancelled;
      }
      guard.markFailed();
      for (var index = 0; index < files.length; index++) {
        if (!sent[index]) {
          onAlert?.call(TransferAlert(
            fileName: manifest.files[index].name,
            status: TransferAlertStatus.failed,
          ));
        }
      }
      connection.destroy();
      rethrow;
    } finally {
      cancellation?.unbind();
      if (!connection.isClosed) await connection.close();
    }
  }

  Future<ReceiverSessionResult> receiveBatch({
    required TcpFrameConnection connection,
    required Directory destinationDirectory,
    required Future<bool> Function(TransferManifest manifest) approve,
    ProtocolFrame? initialFrame,
    Duration approvalTimeout = const Duration(seconds: 30),
    TransferCancellation? cancellation,
    void Function(int receivedBytes, int totalBytes)? onProgress,
    void Function(TransferAlert alert)? onAlert,
    Future<void> Function(List<File> files)? finalizeFiles,
    Duration idleTimeout = const Duration(seconds: 60),
  }) async {
    final guard = ReceiverProtocolGuard()..markHelloAuthenticated();
    TransferManifest? manifest;
    final receivedFiles = <File>[];
    final receivedIndexes = <bool>[];
    cancellation?.bind(() {
      if (guard.phase != ReceiverProtocolPhase.completed &&
          guard.phase != ReceiverProtocolPhase.rejected) {
        connection.destroy();
      }
    });

    void reportCancelled() {
      final currentManifest = manifest;
      if (currentManifest == null) return;
      for (var i = 0; i < currentManifest.files.length; i++) {
        if (!receivedIndexes[i]) {
          onAlert?.call(TransferAlert(
            fileName: currentManifest.files[i].name,
            status: TransferAlertStatus.cancelled,
          ));
        }
      }
    }

    try {
      final accepted = await TcpReceiverHandshake.receiveManifestAndRequestApproval(
        connection: connection,
        initialFrame: initialFrame,
        timeout: approvalTimeout,
        approve: (incoming) async {
          guard.receiveManifest(incoming);
          manifest = incoming;
          receivedIndexes.addAll(List<bool>.filled(incoming.files.length, false));
          final approved = await approve(incoming);
          if (approved) {
            guard.approve();
          } else {
            guard.reject();
          }
          return approved;
        },
      );

      if (!accepted) {
        final rejectedManifest = manifest;
        if (rejectedManifest != null) {
          for (final entry in rejectedManifest.files) {
            onAlert?.call(TransferAlert(
              fileName: entry.name,
              status: TransferAlertStatus.rejected,
            ));
          }
        }
        return const ReceiverSessionResult(
          outcome: ReceiverSessionOutcome.rejected,
          files: [],
        );
      }

      final result = await const StreamingFileReceiver().receiveBatch(
        connection: connection,
        manifest: manifest!,
        guard: guard,
        destinationDirectory: destinationDirectory,
        onProgress: onProgress,
        idleTimeout: idleTimeout,
        onFileReceived: (index, file) {
          receivedIndexes[index] = true;
          receivedFiles.add(file);
          // Success alerts are emitted only after final storage and FILE_OK.
        },
      );
      if (result.cancelled) {
        reportCancelled();
      } else {
        await finalizeFiles?.call(result.files);
        await connection.sendFrame(ProtocolFrame(ProtocolMessageType.fileOk, const []))
            .timeout(const Duration(seconds: 60));
        for (var index = 0; index < manifest!.files.length; index++) {
          onAlert?.call(TransferAlert(
            fileName: manifest!.files[index].name,
            status: TransferAlertStatus.received,
          ));
        }
      }
      return ReceiverSessionResult(
        outcome: result.cancelled
            ? ReceiverSessionOutcome.cancelled
            : ReceiverSessionOutcome.completed,
        files: result.files,
      );
    } on Object {
      if (cancellation?.isCancelled == true && manifest != null) {
        guard.markCancelled();
        reportCancelled();
        return ReceiverSessionResult(
          outcome: ReceiverSessionOutcome.cancelled,
          files: List<File>.unmodifiable(receivedFiles),
        );
      }
      guard.markFailed();
      final currentManifest = manifest;
      if (currentManifest != null) {
        for (var index = 0; index < currentManifest.files.length; index++) {
          if (!receivedIndexes[index]) {
            onAlert?.call(TransferAlert(
              fileName: currentManifest.files[index].name,
              status: TransferAlertStatus.failed,
            ));
          }
        }
      }
      connection.destroy();
      rethrow;
    } finally {
      cancellation?.unbind();
      if (!connection.isClosed) await connection.close();
    }
  }
}
