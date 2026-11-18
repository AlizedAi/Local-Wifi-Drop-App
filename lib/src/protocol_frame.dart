import 'dart:convert';
import 'dart:typed_data';

enum ProtocolMessageType {
  hello(1), manifest(2), accept(3), reject(4), fileBegin(5), fileData(6),
  fileEnd(7), fileOk(8), fileError(9), cancel(10), batchDone(11), textMessage(12), chatMessage(13), chatAck(14);
  const ProtocolMessageType(this.code);
  final int code;
  static ProtocolMessageType fromCode(int code) {
    for (final value in values) {
      if (value.code == code) return value;
    }
    throw FormatException('Unknown protocol message type: $code');
  }
}

/// UTF-8 text payload used for standalone messages (not file transfers).
class TextMessagePayload {
  TextMessagePayload(String text)
      : text = text,
        bytes = Uint8List.fromList(utf8.encode(text)) {
    if (text.trim().isEmpty || bytes.length > maxBytes) {
      throw const FormatException('Message is empty or too large.');
    }
  }

  TextMessagePayload._(this.text, this.bytes);

  static const int maxBytes = 64 * 1024;
  final String text;
  final Uint8List bytes;

  static TextMessagePayload decode(List<int> payload) {
    if (payload.isEmpty || payload.length > maxBytes) {
      throw const FormatException('Message length is invalid.');
    }
    try {
      final decoded = utf8.decode(payload, allowMalformed: false);
      if (decoded.trim().isEmpty) {
        throw const FormatException('Message is empty.');
      }
      return TextMessagePayload._(decoded, Uint8List.fromList(payload));
    } on FormatException {
      throw const FormatException('Message is not valid UTF-8.');
    }
  }
}

/// A message sent after the initial foreground chat approval.
/// The message ID lets each direction acknowledge messages independently.
class ChatMessagePayload {
  ChatMessagePayload({required this.messageId, required this.text})
      : bytes = _encode(messageId, text);

  static const int headerBytes = 4;
  final int messageId;
  final String text;
  final Uint8List bytes;

  static Uint8List _encode(int messageId, String text) {
    if (messageId < 0 || messageId > 0xffffffff ||
        text.trim().isEmpty) {
      throw const FormatException('Chat message ID or text is invalid.');
    }
    final encoded = utf8.encode(text);
    if (encoded.length > TextMessagePayload.maxBytes) {
      throw const FormatException('Chat message is too large.');
    }
    final output = Uint8List(headerBytes + encoded.length);
    ByteData.sublistView(output).setUint32(0, messageId, Endian.big);
    output.setRange(headerBytes, output.length, encoded);
    return output;
  }

  static ChatMessagePayload decode(List<int> payload) {
    if (payload.length <= headerBytes ||
        payload.length > headerBytes + TextMessagePayload.maxBytes) {
      throw const FormatException('Chat message payload length is invalid.');
    }
    final bytes = payload is Uint8List ? payload : _validatedBytes(payload);
    final messageId = ByteData.sublistView(bytes, 0, headerBytes)
        .getUint32(0, Endian.big);
    try {
      final text = utf8.decode(
        Uint8List.sublistView(bytes, headerBytes),
        allowMalformed: false,
      );
      if (text.trim().isEmpty) {
        throw const FormatException('Chat message is empty.');
      }
      return ChatMessagePayload(messageId: messageId, text: text);
    } on FormatException {
      throw const FormatException('Chat message is not valid UTF-8.');
    }
  }
}

/// Acknowledges one CHAT_MESSAGE frame after it has been added to the
/// receiving device's in-memory conversation.
class ChatMessageAckPayload {
  ChatMessageAckPayload({required this.messageId}) {
    if (messageId < 0 || messageId > 0xffffffff) {
      throw const FormatException('Chat acknowledgement ID is invalid.');
    }
    bytes = Uint8List(4);
    ByteData.sublistView(bytes).setUint32(0, messageId, Endian.big);
  }

  ChatMessageAckPayload._(this.messageId, this.bytes);

  final int messageId;
  late final Uint8List bytes;

  static ChatMessageAckPayload decode(List<int> payload) {
    if (payload.length != 4) {
      throw const FormatException('Chat acknowledgement must contain 4 bytes.');
    }
    final bytes = payload is Uint8List ? payload : _validatedBytes(payload);
    return ChatMessageAckPayload._(
      ByteData.sublistView(bytes).getUint32(0, Endian.big),
      Uint8List.fromList(bytes),
    );
  }
}

/// Public construction copies input. Decoder-created frames own their payload.
class ProtocolFrame {
  ProtocolFrame(this.type, List<int> payload)
      : payload = _validatedBytes(payload);
  ProtocolFrame._owned(this.type, this.payload);
  final ProtocolMessageType type;
  final Uint8List payload;
  Uint8List encode() {
    final bodyLength = 1 + payload.length;
    if (bodyLength > ProtocolFrameDecoder.defaultMaxFrameLength) {
      throw const FormatException('Protocol frame is too large.');
    }
    final output = Uint8List(4 + bodyLength);
    ByteData.sublistView(output).setUint32(0, bodyLength, Endian.big);
    output[4] = type.code;
    output.setRange(5, output.length, payload);
    return output;
  }
}

/// Incremental decoder. Received payloads are views over one owned frame buffer,
/// avoiding an additional copy of large FILE_DATA frames.
class ProtocolFrameDecoder {
  ProtocolFrameDecoder({this.maxFrameLength = defaultMaxFrameLength})
      : _header = Uint8List(4) {
    if (maxFrameLength < 1 || maxFrameLength > defaultMaxFrameLength) {
      throw ArgumentError.value(maxFrameLength, 'maxFrameLength');
    }
  }
  static const int defaultMaxFrameLength = 256 * 1024;
  final int maxFrameLength;
  final Uint8List _header;
  int _headerOffset = 0;
  Uint8List? _body;
  int _bodyOffset = 0;
  bool _failed = false;

  List<ProtocolFrame> add(List<int> bytes) {
    final frames = <ProtocolFrame>[];
    addEach(bytes, frames.add);
    return frames;
  }

  void addEach(List<int> bytes, void Function(ProtocolFrame) onFrame) {
    if (_failed) throw StateError('Decoder cannot be used after a framing error.');
    var inputOffset = 0;
    try {
      while (inputOffset < bytes.length) {
        if (_body == null) {
          final count = _copy(bytes, inputOffset, _header, _headerOffset,
              _header.length - _headerOffset);
          inputOffset += count;
          _headerOffset += count;
          if (_headerOffset < _header.length) continue;
          final length = ByteData.sublistView(_header).getUint32(0, Endian.big);
          if (length < 1 || length > maxFrameLength) {
            throw FormatException('Invalid protocol frame length: $length');
          }
          _body = Uint8List(length);
          _bodyOffset = 0;
        }
        final body = _body!;
        final count = _copy(bytes, inputOffset, body, _bodyOffset,
            body.length - _bodyOffset);
        inputOffset += count;
        _bodyOffset += count;
        if (_bodyOffset == body.length) {
          final type = ProtocolMessageType.fromCode(body[0]);
          onFrame(ProtocolFrame._owned(
            type, Uint8List.sublistView(body, 1),
          ));
          _body = null;
          _bodyOffset = 0;
          _headerOffset = 0;
        }
      }
    } on Object {
      _failed = true;
      rethrow;
    }
  }

  static int _copy(List<int> source, int sourceOffset, Uint8List destination,
      int destinationOffset, int maximum) {
    final count = (source.length - sourceOffset).clamp(0, maximum).toInt();
    if (count > 0) {
      destination.setRange(destinationOffset, destinationOffset + count,
          source, sourceOffset);
    }
    return count;
  }
  bool get isAtFrameBoundary => _headerOffset == 0 && _body == null;
}

class FileDataChunk {
  FileDataChunk({
    required this.fileIndex,
    required this.offset,
    required List<int> data,
  }) : data = _validatedBytes(data) {
    _validate();
  }
  FileDataChunk._view({
    required this.fileIndex,
    required this.offset,
    required this.data,
  }) {
    _validate();
  }
  static const int headerBytes = 12;
  static const int maxDataBytes = 64 * 1024;
  final int fileIndex;
  final int offset;
  final Uint8List data;
  void _validate() {
    if (fileIndex < 0 || fileIndex > 0xffffffff) {
      throw const FormatException('File index is outside the allowed range.');
    }
    if (offset < 0 || offset > 0x7fffffffffffffff) {
      throw const FormatException('File offset is outside the allowed range.');
    }
    if (data.isEmpty || data.length > maxDataBytes) {
      throw const FormatException('File data chunk size is invalid.');
    }
  }
  Uint8List encodePayload() {
    final output = Uint8List(headerBytes + data.length);
    final header = ByteData.sublistView(output);
    header.setUint32(0, fileIndex, Endian.big);
    header.setUint64(4, offset, Endian.big);
    output.setRange(headerBytes, output.length, data);
    return output;
  }
  static FileDataChunk decodePayload(List<int> payload) {
    if (payload.length <= headerBytes ||
        payload.length > headerBytes + maxDataBytes) {
      throw const FormatException('File data payload size is invalid.');
    }
    final bytes = payload is Uint8List ? payload : _validatedBytes(payload);
    final header = ByteData.sublistView(bytes, 0, headerBytes);
    if ((bytes[4] & 0x80) != 0) {
      throw const FormatException('File offset is outside the allowed range.');
    }
    final offset = header.getUint64(4, Endian.big);
    if (offset > 0x7fffffffffffffff) {
      throw const FormatException('File offset is outside the allowed range.');
    }
    return FileDataChunk._view(
      fileIndex: header.getUint32(0, Endian.big),
      offset: offset,
      data: Uint8List.sublistView(bytes, headerBytes),
    );
  }
}


/// FILE_END carries the SHA-256 digest computed during the streaming pass.
class FileEndPayload {
  FileEndPayload({required this.fileIndex, required List<int> digest}) : digest = _validatedBytes(digest) {
    if (fileIndex < 0 || fileIndex > 0xffffffff || digest.length != 32) throw const FormatException('FILE_END index or digest is invalid.');
  }
  static const int payloadBytes = 36;
  final int fileIndex;
  final Uint8List digest;
  Uint8List encodePayload() {
    final output = Uint8List(payloadBytes);
    ByteData.sublistView(output).setUint32(0, fileIndex, Endian.big);
    output.setRange(4, payloadBytes, digest);
    return output;
  }
  static FileEndPayload decodePayload(List<int> payload) {
    if (payload.length != payloadBytes || payload.any((b) => b < 0 || b > 255)) throw const FormatException('FILE_END must contain an index and SHA-256 digest.');
    final bytes = payload is Uint8List ? payload : Uint8List.fromList(payload);
    return FileEndPayload(fileIndex: ByteData.sublistView(bytes).getUint32(0, Endian.big), digest: Uint8List.sublistView(bytes, 4));
  }
}

Uint8List _validatedBytes(List<int> bytes) {
  if (bytes.any((value) => value < 0 || value > 255)) {
    throw const FormatException('Byte values must be between 0 and 255.');
  }
  return Uint8List.fromList(bytes);
}
