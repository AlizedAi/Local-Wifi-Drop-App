import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_wifi_drop/src/protocol_frame.dart';

void main() {
  group('ProtocolFrame', () {
    test('round trips a control frame', () {
      final original = ProtocolFrame(
        ProtocolMessageType.hello,
        [1, 2, 3, 4],
      );

      final decoded = ProtocolFrameDecoder().add(original.encode()).single;

      expect(decoded.type, ProtocolMessageType.hello);
      expect(decoded.payload, [1, 2, 3, 4]);
    });

    test('rejects payload bytes outside the byte range', () {
      expect(
        () => ProtocolFrame(ProtocolMessageType.hello, [256]),
        throwsFormatException,
      );
    });

    test('decodes a frame split across arbitrary TCP reads', () {
      final encoded = ProtocolFrame(
        ProtocolMessageType.manifest,
        List<int>.generate(257, (index) => index & 0xff),
      ).encode();
      final decoder = ProtocolFrameDecoder();
      final frames = <ProtocolFrame>[];

      for (final byte in encoded) {
        frames.addAll(decoder.add([byte]));
      }

      expect(frames, hasLength(1));
      expect(frames.single.type, ProtocolMessageType.manifest);
      expect(frames.single.payload, encoded.sublist(5));
      expect(decoder.isAtFrameBoundary, isTrue);
    });

    test('decodes multiple frames coalesced in one read', () {
      final first = ProtocolFrame(ProtocolMessageType.accept, [9]).encode();
      final second = ProtocolFrame(ProtocolMessageType.cancel, []).encode();
      final combined = Uint8List.fromList([...first, ...second]);

      final frames = ProtocolFrameDecoder().add(combined);

      expect(frames.map((frame) => frame.type), [
        ProtocolMessageType.accept,
        ProtocolMessageType.cancel,
      ]);
    });

    test('rejects a zero-length frame', () {
      expect(
        () => ProtocolFrameDecoder().add([0, 0, 0, 0]),
        throwsFormatException,
      );
    });

    test('rejects a frame above the configured maximum', () {
      expect(
        () => ProtocolFrameDecoder().add([0, 4, 0, 1]),
        throwsFormatException,
      );
    });

    test('rejects unknown message identifiers', () {
      expect(
        () => ProtocolFrameDecoder().add([0, 0, 0, 1, 255]),
        throwsFormatException,
      );
    });

    test('decoder cannot continue after malformed input', () {
      final decoder = ProtocolFrameDecoder();
      expect(() => decoder.add([0, 0, 0, 0]), throwsFormatException);
      expect(() => decoder.add([0, 0, 0, 1, 1]), throwsStateError);
    });

    test('reports an incomplete frame boundary', () {
      final decoder = ProtocolFrameDecoder();
      decoder.add([0, 0]);

      expect(decoder.isAtFrameBoundary, isFalse);
    });
  });

  group('TextMessagePayload', () {
    test('round trips UTF-8 including Persian and emoji', () {
      const text = 'Hello 👋 سلام';
      final encoded = TextMessagePayload(text).bytes;
      expect(TextMessagePayload.decode(encoded).text, text);
    });

    test('rejects empty, oversized and malformed messages', () {
      expect(() => TextMessagePayload('  '), throwsFormatException);
      expect(
        () => TextMessagePayload(List<String>.filled(TextMessagePayload.maxBytes + 1, 'x').join()),
        throwsFormatException,
      );
      expect(
        () => TextMessagePayload.decode([0xff, 0xfe]),
        throwsFormatException,
      );
    });
  });

  group('ChatMessagePayload', () {
    test('round trips message ID and UTF-8 text', () {
      final original = ChatMessagePayload(
        messageId: 42,
        text: 'سلام 👋 hello',
      );
      final decoded = ChatMessagePayload.decode(original.bytes);
      expect(decoded.messageId, 42);
      expect(decoded.text, 'سلام 👋 hello');
    });

    test('rejects invalid IDs, empty text and malformed payloads', () {
      expect(
        () => ChatMessagePayload(messageId: -1, text: 'hello'),
        throwsFormatException,
      );
      expect(
        () => ChatMessagePayload(messageId: 1, text: '  '),
        throwsFormatException,
      );
      expect(
        () => ChatMessagePayload.decode([0, 0, 0, 1]),
        throwsFormatException,
      );
      expect(
        () => ChatMessagePayload.decode([0, 0, 0, 1, 0xff]),
        throwsFormatException,
      );
    });
  });

  group('ChatMessageAckPayload', () {
    test('round trips a message ID', () {
      final original = ChatMessageAckPayload(messageId: 0x12345678);
      final decoded = ChatMessageAckPayload.decode(original.bytes);
      expect(decoded.messageId, 0x12345678);
    });

    test('rejects malformed acknowledgement lengths', () {
      expect(() => ChatMessageAckPayload.decode([1, 2, 3]), throwsFormatException);
      expect(() => ChatMessageAckPayload.decode([1, 2, 3, 4, 5]), throwsFormatException);
    });
  });

  group('FileEndPayload', () {
    test('round trips file index and a 32-byte SHA-256 digest', () {
      final original = FileEndPayload(
        fileIndex: 9,
        digest: List<int>.generate(32, (index) => index),
      );

      final decoded = FileEndPayload.decodePayload(original.encodePayload());

      expect(decoded.fileIndex, 9);
      expect(decoded.digest, List<int>.generate(32, (index) => index));
      expect(decoded.encodePayload(), original.encodePayload());
    });

    test('rejects a truncated or oversized digest payload', () {
      expect(
        () => FileEndPayload.decodePayload(List<int>.filled(35, 0)),
        throwsFormatException,
      );
      expect(
        () => FileEndPayload.decodePayload(List<int>.filled(37, 0)),
        throwsFormatException,
      );
    });

    test('rejects digest values outside the byte range in the constructor', () {
      expect(
        () => FileEndPayload(fileIndex: 0, digest: [...List<int>.filled(31, 0), 256]),
        throwsFormatException,
      );
    });

    test('rejects digest values outside the byte range', () {
      expect(
        () => FileEndPayload.decodePayload([...List<int>.filled(35, 0), 256]),
        throwsFormatException,
      );
    });

    test('rejects a digest that is not exactly 32 bytes', () {
      expect(
        () => FileEndPayload(fileIndex: 0, digest: List<int>.filled(31, 0)),
        throwsFormatException,
      );
    });
  });

  group('FileDataChunk', () {
    test('round trips file index, 64-bit offset, and bytes', () {
      final original = FileDataChunk(
        fileIndex: 7,
        offset: 0x123456789,
        data: [10, 20, 30, 40],
      );

      final decoded = FileDataChunk.decodePayload(original.encodePayload());

      expect(decoded.fileIndex, 7);
      expect(decoded.offset, 0x123456789);
      expect(decoded.data, [10, 20, 30, 40]);
    });

    test('rejects data bytes outside the byte range', () {
      expect(
        () => FileDataChunk(fileIndex: 0, offset: 0, data: [256]),
        throwsFormatException,
      );
    });

    test('rejects empty data', () {
      expect(
        () => FileDataChunk(fileIndex: 0, offset: 0, data: []),
        throwsFormatException,
      );
    });

    test('rejects an oversized data chunk', () {
      expect(
        () => FileDataChunk(
          fileIndex: 0,
          offset: 0,
          data: List<int>.filled(FileDataChunk.maxDataBytes + 1, 1),
        ),
        throwsFormatException,
      );
    });

    test('rejects truncated payloads', () {
      expect(
        () => FileDataChunk.decodePayload(List<int>.filled(12, 0)),
        throwsFormatException,
      );
    });
  });
}
