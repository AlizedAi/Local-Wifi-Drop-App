import 'dart:typed_data';

import 'protocol_frame.dart';
import 'transfer_manifest.dart';

enum ReceiverProtocolPhase {
  awaitingHello,
  awaitingManifest,
  awaitingApproval,
  transferring,
  completed,
  rejected,
  cancelled,
  failed,
}

/// Enforces the receiver-side message order after the one-time token layer has
/// authenticated the sender. This class does not open sockets or write files.
class ReceiverProtocolGuard {
  ReceiverProtocolPhase _phase = ReceiverProtocolPhase.awaitingHello;
  TransferManifest? _manifest;
  int _nextFileIndex = 0;
  int? _currentFileIndex;
  int _currentFileBytes = 0;

  ReceiverProtocolPhase get phase => _phase;
  TransferManifest? get manifest => _manifest;
  int? get currentFileIndex => _currentFileIndex;
  int get currentFileBytes => _currentFileBytes;

  void markCancelled() {
    if (_phase == ReceiverProtocolPhase.completed ||
        _phase == ReceiverProtocolPhase.rejected ||
        _phase == ReceiverProtocolPhase.failed) {
      return;
    }
    _currentFileIndex = null;
    _currentFileBytes = 0;
    _phase = ReceiverProtocolPhase.cancelled;
  }

  void markHelloAuthenticated() {
    _expectPhase(
      ReceiverProtocolPhase.awaitingHello,
      'HELLO authentication',
    );
    _phase = ReceiverProtocolPhase.awaitingManifest;
  }

  void receiveManifest(TransferManifest manifest) {
    _expectPhase(
      ReceiverProtocolPhase.awaitingManifest,
      'MANIFEST',
    );
    _manifest = manifest;
    _phase = ReceiverProtocolPhase.awaitingApproval;
  }

  void approve() {
    _expectPhase(ReceiverProtocolPhase.awaitingApproval, 'receiver approval');
    _phase = ReceiverProtocolPhase.transferring;
  }

  void reject() {
    _expectPhase(ReceiverProtocolPhase.awaitingApproval, 'receiver rejection');
    _phase = ReceiverProtocolPhase.rejected;
  }

  /// Marks an I/O or integrity failure outside protocol-frame validation.
  void markFailed() {
    if (_phase == ReceiverProtocolPhase.completed ||
        _phase == ReceiverProtocolPhase.cancelled ||
        _phase == ReceiverProtocolPhase.rejected) {
      return;
    }
    _currentFileIndex = null;
    _currentFileBytes = 0;
    _phase = ReceiverProtocolPhase.failed;
  }

  void receiveFrame(ProtocolFrame frame) {
    if (frame.type == ProtocolMessageType.cancel) {
      if (_phase != ReceiverProtocolPhase.awaitingManifest &&
          _phase != ReceiverProtocolPhase.awaitingApproval &&
          _phase != ReceiverProtocolPhase.transferring) {
        _fail('CANCEL is not valid in the current phase.');
      }
      if (frame.payload.isNotEmpty) {
        _fail('CANCEL payload must be empty.');
      }
      _currentFileIndex = null;
      _currentFileBytes = 0;
      _phase = ReceiverProtocolPhase.cancelled;
      return;
    }

    if (_phase != ReceiverProtocolPhase.transferring) {
      _fail('File messages are not allowed before receiver approval.');
    }

    try {
      switch (frame.type) {
        case ProtocolMessageType.fileBegin:
          _receiveFileBegin(frame.payload);
          break;
        case ProtocolMessageType.fileData:
          _receiveFileData(frame.payload);
          break;
        case ProtocolMessageType.fileEnd:
          _receiveFileEnd(frame.payload);
          break;
        case ProtocolMessageType.batchDone:
          _receiveBatchDone(frame.payload);
          break;
        default:
          _fail('Unexpected message type: ${frame.type.name}.');
      }
    } on Object {
      if (_phase != ReceiverProtocolPhase.completed &&
          _phase != ReceiverProtocolPhase.cancelled) {
        _phase = ReceiverProtocolPhase.failed;
      }
      rethrow;
    }
  }

  void _receiveFileBegin(Uint8List payload) {
    final manifest = _manifest!;
    if (_currentFileIndex != null) {
      _fail('A file is already open.');
    }
    if (payload.length != 12) {
      _fail('FILE_BEGIN payload must contain 12 bytes.');
    }
    if (_nextFileIndex >= manifest.files.length) {
      _fail('Manifest contains no more files.');
    }

    final data = ByteData.sublistView(payload);
    final index = data.getUint32(0, Endian.big);
    if ((payload[4] & 0x80) != 0) {
      _fail('FILE_BEGIN size is outside the allowed range.');
    }
    final size = data.getUint64(4, Endian.big);
    final expected = manifest.files[_nextFileIndex];

    if (index != _nextFileIndex || size != expected.size) {
      _fail('FILE_BEGIN does not match the next manifest entry.');
    }
    _currentFileIndex = index;
    _currentFileBytes = 0;
  }

  void _receiveFileData(Uint8List payload) {
    final current = _currentFileIndex;
    if (current == null) {
      _fail('FILE_DATA arrived without FILE_BEGIN.');
    }
    final chunk = FileDataChunk.decodePayload(payload);
    final expectedSize = _manifest!.files[current].size;
    if (chunk.fileIndex != current ||
        chunk.offset != _currentFileBytes ||
        chunk.data.length > expectedSize - _currentFileBytes) {
      _fail('FILE_DATA index, offset, or length is invalid.');
    }
    _currentFileBytes += chunk.data.length;
  }

  void _receiveFileEnd(Uint8List payload) {
    final current = _currentFileIndex;
    if (current == null) {
      _fail('FILE_END arrived without FILE_BEGIN.');
    }
    final index = FileEndPayload.decodePayload(payload).fileIndex;
    final expectedSize = _manifest!.files[current].size;
    if (index != current || _currentFileBytes != expectedSize) {
      _fail('FILE_END arrived before the exact file size was received.');
    }
    _nextFileIndex++;
    _currentFileIndex = null;
    _currentFileBytes = 0;
  }

  void _receiveBatchDone(Uint8List payload) {
    if (payload.isNotEmpty ||
        _currentFileIndex != null ||
        _nextFileIndex != _manifest!.files.length) {
      _fail('BATCH_DONE arrived before all files were completed.');
    }
    _phase = ReceiverProtocolPhase.completed;
  }

  void _expectPhase(ReceiverProtocolPhase expected, String operation) {
    if (_phase != expected) {
      throw StateError(
        '$operation is invalid while receiver is ${_phase.name}.',
      );
    }
  }

  Never _fail(String message) {
    _phase = ReceiverProtocolPhase.failed;
    throw FormatException(message);
  }
}
