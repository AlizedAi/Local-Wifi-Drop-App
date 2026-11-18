import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'protocol_frame.dart';
import 'receiver_protocol_guard.dart';
import 'tcp_frame_connection.dart';
import 'transfer_manifest.dart';

/// Result of receiving one approved batch.
class StreamingReceiveResult {
  const StreamingReceiveResult({
    required this.cancelled,
    required this.files,
  });

  final bool cancelled;
  final List<File> files;
}

/// Receives a batch with bounded memory and verifies each file before publish.
class StreamingFileReceiver {
  const StreamingFileReceiver();

  Future<StreamingReceiveResult> receiveBatch({
    required TcpFrameConnection connection,
    required TransferManifest manifest,
    required ReceiverProtocolGuard guard,
    required Directory destinationDirectory,
    void Function(int receivedBytes, int totalBytes)? onProgress,
    void Function(int fileIndex, File file)? onFileReceived,
    Duration idleTimeout = const Duration(seconds: 60),
  }) async {
    if (guard.phase != ReceiverProtocolPhase.transferring ||
        guard.manifest != manifest) {
      throw StateError('Receiver guard must be approved for this manifest.');
    }
    await destinationDirectory.create(recursive: true);

    final completed = <File>[];
    RandomAccessFile? activeHandle;
    File? activeTemporary;
    Sink<List<int>>? digestInput;
    final digestOutput = <Digest>[];
    var currentIndex = -1;
    var currentBytes = 0;
    var completedBytes = 0;

    Future<void> discardActive() async {
      await activeHandle?.close();
      activeHandle = null;
      digestInput?.close();
      digestInput = null;
      if (activeTemporary != null && await activeTemporary!.exists()) {
        await activeTemporary!.delete();
      }
      activeTemporary = null;
    }

    try {
      while (true) {
        final frame = await connection.readFrame().timeout(idleTimeout);
        if (frame == null) {
          throw const SocketException('Sender disconnected before batch completion.');
        }

        if (frame.type == ProtocolMessageType.cancel) {
          guard.receiveFrame(frame);
          await discardActive();
          return StreamingReceiveResult(
            cancelled: true,
            files: List<File>.unmodifiable(completed),
          );
        }

        switch (frame.type) {
          case ProtocolMessageType.fileBegin:
            guard.receiveFrame(frame);
            final payload = ByteData.sublistView(frame.payload);
            currentIndex = payload.getUint32(0, Endian.big);
            currentBytes = 0;
            digestOutput.clear();
            digestInput = sha256.startChunkedConversion(
              _DigestListSink(digestOutput),
            );
            activeTemporary = await _createTemporaryFile(
              destinationDirectory,
              manifest.batchId,
              currentIndex,
            );
            activeHandle = await activeTemporary!.open(mode: FileMode.writeOnly);
            break;

          case ProtocolMessageType.fileData:
            final chunk = FileDataChunk.decodePayload(frame.payload);
            guard.receiveFrame(frame);
            final handle = activeHandle;
            final digest = digestInput;
            if (handle == null || digest == null) {
              throw const FormatException('FILE_DATA has no active temporary file.');
            }
            await handle.writeFrom(chunk.data);
            digest.add(chunk.data);
            currentBytes += chunk.data.length;
            onProgress?.call(completedBytes + currentBytes, manifest.totalBytes);
            break;

          case ProtocolMessageType.fileEnd:
            final end = FileEndPayload.decodePayload(frame.payload);
            final digest = digestInput;
            final temporary = activeTemporary;
            final handle = activeHandle;
            if (digest == null || temporary == null || handle == null ||
                end.fileIndex != currentIndex) {
              throw const FormatException('FILE_END does not match the active file.');
            }
            digest.close();
            digestInput = null;
            if (digestOutput.length != 1 ||
                !_constantTimeEquals(digestOutput.single.bytes, end.digest)) {
              throw const FormatException('Received file SHA-256 does not match FILE_END.');
            }
            guard.receiveFrame(frame);
            await handle.flush();
            await handle.close();
            activeHandle = null;
            final destination = await _availableDestination(
              destinationDirectory,
              manifest.files[currentIndex].name,
            );
            final saved = await temporary.rename(destination.path);
            completed.add(saved);
            onFileReceived?.call(currentIndex, saved);
            activeTemporary = null;
            completedBytes += currentBytes;
            currentBytes = 0;
            currentIndex = -1;
            onProgress?.call(completedBytes, manifest.totalBytes);
            break;

          case ProtocolMessageType.batchDone:
            guard.receiveFrame(frame);
            if (activeTemporary != null || activeHandle != null) {
              throw const FormatException('BATCH_DONE arrived with an open file.');
            }
            return StreamingReceiveResult(
              cancelled: false,
              files: List<File>.unmodifiable(completed),
            );

          default:
            guard.receiveFrame(frame);
            throw FormatException('Unexpected receiver message: ${frame.type.name}.');
        }
      }
    } on Object {
      await discardActive();
      guard.markFailed();
      rethrow;
    }
  }

  Future<File> _createTemporaryFile(
    Directory directory,
    List<int> batchId,
    int fileIndex,
  ) async {
    final id = batchId.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    for (var attempt = 0; attempt < 100; attempt++) {
      final suffix = attempt == 0 ? '' : '-$attempt';
      final file = File('${directory.path}/.wifi-drop-$id-$fileIndex$suffix.part');
      try {
        await file.create(exclusive: true);
        return file;
      } on FileSystemException {
        if (!await file.exists()) rethrow;
      }
    }
    throw FileSystemException('Could not reserve a temporary receive file.', directory.path);
  }

  Future<File> _availableDestination(Directory directory, String name) async {
    final dot = name.lastIndexOf('.');
    final hasExtension = dot > 0;
    final stem = hasExtension ? name.substring(0, dot) : name;
    final extension = hasExtension ? name.substring(dot) : '';
    for (var index = 0; index < 10000; index++) {
      final candidate = index == 0 ? name : '$stem ($index)$extension';
      final file = File('${directory.path}/$candidate');
      if (!await file.exists()) return file;
    }
    throw FileSystemException('No available destination filename.', directory.path);
  }

  bool _constantTimeEquals(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var index = 0; index < left.length; index++) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }
}

class _DigestListSink implements Sink<Digest> {
  _DigestListSink(this.values);

  final List<Digest> values;
  bool _closed = false;

  @override
  void add(Digest value) {
    if (_closed) throw StateError('Digest sink is closed.');
    values.add(value);
  }

  @override
  void close() {
    if (_closed) throw StateError('Digest sink is already closed.');
    _closed = true;
  }
}
