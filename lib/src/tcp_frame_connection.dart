import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'protocol_frame.dart';

/// Framed TCP stream. Reads are demand-driven; only one read may be active.
/// Writes are serialized by the caller and use Socket's bounded flow control.
class TcpFrameConnection {
  TcpFrameConnection._(this._socket)
      : _iterator = StreamIterator<Uint8List>(_socket) {
    _socket.setOption(SocketOption.tcpNoDelay, true);
  }
  final Socket _socket;
  final StreamIterator<Uint8List> _iterator;
  final ProtocolFrameDecoder _decoder = ProtocolFrameDecoder();
  final Queue<ProtocolFrame> _pending = Queue<ProtocolFrame>();
  bool _reading = false;
  bool _closed = false;
  Future<void> _writeTail = Future<void>.value();
  InternetAddress get remoteAddress => _socket.remoteAddress;
  int get remotePort => _socket.remotePort;
  bool get isClosed => _closed;
  factory TcpFrameConnection.fromSocket(Socket socket) =>
      TcpFrameConnection._(socket);

  Future<ProtocolFrame?> readFrame() async {
    if (_closed) return null;
    if (_reading) throw StateError('Only one readFrame call may be active.');
    _reading = true;
    try {
      while (_pending.isEmpty) {
        if (!await _iterator.moveNext()) {
          if (!_decoder.isAtFrameBoundary) {
            throw const FormatException('Peer closed during a protocol frame.');
          }
          return null;
        }
        _decoder.addEach(_iterator.current, _pending.addLast);
      }
      return _pending.removeFirst();
    } finally {
      _reading = false;
    }
  }

  Future<void> sendFrame(ProtocolFrame frame) {
    if (_closed) return Future<void>.error(StateError('Connection is closed.'));
    final bodyLength = 1 + frame.payload.length;
    if (bodyLength > ProtocolFrameDecoder.defaultMaxFrameLength) {
      return Future<void>.error(
        const FormatException('Protocol frame is too large.'),
      );
    }

    // Serialize concurrent callers so bytes from two frames can never
    // interleave on the same TCP stream.
    final operation = _writeTail.then((_) async {
      if (_closed) throw StateError('Connection is closed.');
      final header = Uint8List(5);
      final data = ByteData.sublistView(header);
      data.setUint32(0, bodyLength, Endian.big);
      header[4] = frame.type.code;
      _socket.add(header);
      _socket.add(frame.payload);
      await _socket.flush();
    });
    // A failed write is returned to its caller but must not poison the queue.
    _writeTail = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _iterator.cancel();
    await _socket.close();
  }
  void destroy() {
    if (_closed) return;
    _closed = true;
    _socket.destroy();
  }
}
