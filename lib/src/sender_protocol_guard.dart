import 'dart:typed_data';

import 'protocol_frame.dart';
import 'transfer_manifest.dart';

enum SenderProtocolPhase {
  awaitingApproval,
  transferring,
  completed,
  rejected,
  cancelled,
  failed,
}

class SenderProtocolGuard {
  SenderProtocolGuard({required TransferManifest manifest})
      : _manifest = manifest;

  final TransferManifest _manifest;
  SenderProtocolPhase _phase = SenderProtocolPhase.awaitingApproval;
  int _nextFileIndex = 0;
  int? _currentFileIndex;
  int _currentFileBytes = 0;

  SenderProtocolPhase get phase => _phase;
  int? get currentFileIndex => _currentFileIndex;
  int get currentFileBytes => _currentFileBytes;

  void receiveDecision(ProtocolFrame frame) {
    _expect(SenderProtocolPhase.awaitingApproval, 'receiver decision');
    if (frame.payload.isNotEmpty) {
      _fail('ACCEPT/REJECT payload must be empty.');
    }
    switch (frame.type) {
      case ProtocolMessageType.accept:
        _phase = SenderProtocolPhase.transferring;
      case ProtocolMessageType.reject:
        _phase = SenderProtocolPhase.rejected;
      default:
        _fail('Expected ACCEPT or REJECT from receiver.');
    }
  }

  void markCancelled() {
    if (_phase == SenderProtocolPhase.awaitingApproval ||
        _phase == SenderProtocolPhase.transferring) {
      _currentFileIndex = null;
      _currentFileBytes = 0;
      _phase = SenderProtocolPhase.cancelled;
    }
  }

  void markFailed() {
    if (_phase == SenderProtocolPhase.completed ||
        _phase == SenderProtocolPhase.rejected ||
        _phase == SenderProtocolPhase.cancelled) {
      return;
    }
    _currentFileIndex = null;
    _currentFileBytes = 0;
    _phase = SenderProtocolPhase.failed;
  }

  void authorizeOutbound(ProtocolFrame frame) {
    if (frame.type == ProtocolMessageType.cancel) {
      if (_phase != SenderProtocolPhase.awaitingApproval &&
          _phase != SenderProtocolPhase.transferring) {
        _fail('CANCEL is not valid in the current sender phase.');
      }
      if (frame.payload.isNotEmpty) _fail('CANCEL payload must be empty.');
      _currentFileIndex = null;
      _currentFileBytes = 0;
      _phase = SenderProtocolPhase.cancelled;
      return;
    }

    if (_phase != SenderProtocolPhase.transferring) {
      _fail('File frames cannot be sent before receiver ACCEPT.');
    }

    try {
      switch (frame.type) {
        case ProtocolMessageType.fileBegin:
          _fileBegin(frame.payload);
        case ProtocolMessageType.fileData:
          _fileData(frame.payload);
        case ProtocolMessageType.fileEnd:
          _fileEnd(frame.payload);
        case ProtocolMessageType.batchDone:
          _batchDone(frame.payload);
        default:
          _fail('Unexpected sender frame: ${frame.type.name}.');
      }
    } on Object {
      if (_phase != SenderProtocolPhase.completed &&
          _phase != SenderProtocolPhase.cancelled) {
        _phase = SenderProtocolPhase.failed;
      }
      rethrow;
    }
  }

  void _fileBegin(Uint8List payload) {
    if (_currentFileIndex != null || payload.length != 12) {
      _fail('FILE_BEGIN is malformed or a file is already open.');
    }
    if (_nextFileIndex >= _manifest.files.length) {
      _fail('Manifest contains no more files.');
    }
    final data = ByteData.sublistView(payload);
    final index = data.getUint32(0, Endian.big);
    if ((payload[4] & 0x80) != 0) {
      _fail('FILE_BEGIN size is outside the allowed range.');
    }
    final size = data.getUint64(4, Endian.big);
    if (index != _nextFileIndex || size != _manifest.files[index].size) {
      _fail('FILE_BEGIN does not match the next manifest entry.');
    }
    _currentFileIndex = index;
    _currentFileBytes = 0;
  }

  void _fileData(Uint8List payload) {
    final current = _currentFileIndex;
    if (current == null) _fail('FILE_DATA arrived without FILE_BEGIN.');
    final chunk = FileDataChunk.decodePayload(payload);
    final expectedSize = _manifest.files[current].size;
    if (chunk.fileIndex != current ||
        chunk.offset != _currentFileBytes ||
        chunk.data.length > expectedSize - _currentFileBytes) {
      _fail('FILE_DATA index, offset, or length is invalid.');
    }
    _currentFileBytes += chunk.data.length;
  }

  void _fileEnd(Uint8List payload) {
    final current = _currentFileIndex;
    if (current == null) _fail('FILE_END is malformed or no file is open.');
    final index = FileEndPayload.decodePayload(payload).fileIndex;
    if (index != current ||
        _currentFileBytes != _manifest.files[current].size) {
      _fail('FILE_END arrived before the exact file size was sent.');
    }
    _nextFileIndex++;
    _currentFileIndex = null;
    _currentFileBytes = 0;
  }

  void _batchDone(Uint8List payload) {
    if (payload.isNotEmpty ||
        _currentFileIndex != null ||
        _nextFileIndex != _manifest.files.length) {
      _fail('BATCH_DONE arrived before all files were sent.');
    }
    _phase = SenderProtocolPhase.completed;
  }

  void _expect(SenderProtocolPhase expected, String action) {
    if (_phase != expected) {
      throw StateError('$action is invalid while sender is ${_phase.name}.');
    }
  }

  Never _fail(String message) {
    _phase = SenderProtocolPhase.failed;
    throw FormatException(message);
  }
}
