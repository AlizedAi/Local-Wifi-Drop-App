import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'protocol_frame.dart';
import 'sender_protocol_guard.dart';
import 'tcp_frame_connection.dart';
import 'transfer_manifest.dart';

class StreamingFileSender {
  const StreamingFileSender();

  Future<void> sendBatch({
    required TcpFrameConnection connection,
    required TransferManifest manifest,
    required SenderProtocolGuard guard,
    required List<File> files,
    void Function(int fileIndex)? onFileStarted,
    void Function(int fileIndex)? onFileSent,
    void Function(int sentBytes, int totalBytes)? onProgress,
    Duration writeTimeout = const Duration(seconds: 60),
  }) async {
    if (files.length != manifest.files.length) {
      throw ArgumentError('Selected file count does not match the manifest.');
    }

    var completedBytes = 0;
    for (var index = 0; index < files.length; index++) {
      onFileStarted?.call(index);
      await _sendFile(
        connection: connection,
        manifestEntry: manifest.files[index],
        file: files[index],
        fileIndex: index,
        guard: guard,
        writeTimeout: writeTimeout,
        onProgress: (fileBytes) =>
            onProgress?.call(completedBytes + fileBytes, manifest.totalBytes),
      );
      completedBytes += manifest.files[index].size;
      onProgress?.call(completedBytes, manifest.totalBytes);
      onFileSent?.call(index);
    }

    final done = ProtocolFrame(ProtocolMessageType.batchDone, const []);
    guard.authorizeOutbound(done);
    await connection.sendFrame(done).timeout(writeTimeout);
  }

  Future<void> _sendFile({
    required TcpFrameConnection connection,
    required TransferFileEntry manifestEntry,
    required File file,
    required int fileIndex,
    required SenderProtocolGuard guard,
    required Duration writeTimeout,
    void Function(int fileBytes)? onProgress,
  }) async {
    final initialLength = await file.length();
    if (initialLength != manifestEntry.size) {
      throw FileSystemException(
        'Selected file size changed after manifest creation.',
        file.path,
      );
    }

    final beginPayload = Uint8List(12);
    final beginData = ByteData.sublistView(beginPayload);
    beginData.setUint32(0, fileIndex, Endian.big);
    beginData.setUint64(4, initialLength, Endian.big);
    final begin = ProtocolFrame(ProtocolMessageType.fileBegin, beginPayload);
    guard.authorizeOutbound(begin);
    await connection.sendFrame(begin).timeout(writeTimeout);

    final digestOutput = <Digest>[];
    final digestInput = sha256.startChunkedConversion(_DigestListSink(digestOutput));
    RandomAccessFile? handle;
    var digestClosed = false;
    var offset = 0;

    try {
      handle = await file.open(mode: FileMode.read);
      while (offset < initialLength) {
        final remaining = initialLength - offset;
        final requested = remaining < FileDataChunk.maxDataBytes
            ? remaining
            : FileDataChunk.maxDataBytes;
        final chunk = await handle.read(requested);
        if (chunk.isEmpty) {
          throw FileSystemException('File became shorter during transfer.', file.path);
        }

        digestInput.add(chunk);
        final payload = Uint8List(FileDataChunk.headerBytes + chunk.length);
        final header = ByteData.sublistView(payload);
        header.setUint32(0, fileIndex, Endian.big);
        header.setUint64(4, offset, Endian.big);
        payload.setRange(FileDataChunk.headerBytes, payload.length, chunk);
        final frame = ProtocolFrame(ProtocolMessageType.fileData, payload);
        guard.authorizeOutbound(frame);
        await connection.sendFrame(frame).timeout(writeTimeout);
        offset += chunk.length;
        onProgress?.call(offset);
      }

      if ((await handle.read(1)).isNotEmpty) {
        throw FileSystemException('File grew during transfer.', file.path);
      }
      digestInput.close();
      digestClosed = true;
      if (digestOutput.length != 1) {
        throw StateError('SHA-256 did not produce exactly one digest.');
      }
      final end = ProtocolFrame(
        ProtocolMessageType.fileEnd,
        FileEndPayload(fileIndex: fileIndex, digest: digestOutput.single.bytes)
            .encodePayload(),
      );
      guard.authorizeOutbound(end);
      await connection.sendFrame(end).timeout(writeTimeout);
    } finally {
      if (!digestClosed) digestInput.close();
      await handle?.close();
    }
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
