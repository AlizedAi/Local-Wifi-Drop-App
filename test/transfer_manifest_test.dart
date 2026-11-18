import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_wifi_drop/src/transfer_manifest.dart';

void main() {
  TransferManifest sample() => TransferManifest(
        batchId: List<int>.filled(16, 7),
        files: [
          TransferFileEntry(name: 'photo.jpg', size: 12345),
          TransferFileEntry(name: 'empty.txt', size: 0),
        ],
      );

  group('TransferManifest', () {
    test('round trips the binary manifest', () {
      final original = sample();
      final decoded = TransferManifest.decode(original.encode());

      expect(decoded.batchId, original.batchId);
      expect(decoded.files, hasLength(2));
      expect(decoded.files[0].name, 'photo.jpg');
      expect(decoded.files[0].size, 12345);
      expect(decoded.files[1].size, 0);
      expect(decoded.totalBytes, 12345);
    });

    test('rejects unsupported schema version', () {
      final bytes = sample().encode();
      bytes[0] = 2;

      expect(() => TransferManifest.decode(bytes), throwsFormatException);
    });

    test('rejects empty file count', () {
      final empty = Uint8List(19);
      empty[0] = 1;
      ByteData.sublistView(empty).setUint16(17, 0, Endian.big);

      expect(() => TransferManifest.decode(empty), throwsFormatException);
    });

    test('rejects truncated file entries', () {
      final bytes = sample().encode();

      expect(
        () => TransferManifest.decode(bytes.sublist(0, bytes.length - 1)),
        throwsFormatException,
      );
    });

    test('rejects trailing bytes', () {
      final bytes = [...sample().encode(), 0];

      expect(() => TransferManifest.decode(bytes), throwsFormatException);
    });

    test('rejects invalid UTF-8 filenames', () {
      final bytes = Uint8List.fromList([
        1,
        ...List<int>.filled(16, 1),
        0,
        1,
        0,
        1,
        0xff,
        ...List<int>.filled(8, 0),
      ]);

      expect(() => TransferManifest.decode(bytes), throwsFormatException);
    });

    test('rejects duplicate filenames case-insensitively', () {
      expect(
        () => TransferManifest(
          batchId: List<int>.filled(16, 1),
          files: [
            TransferFileEntry(name: 'Photo.JPG', size: 1),
            TransferFileEntry(name: 'photo.jpg', size: 1),
          ],
        ),
        throwsFormatException,
      );
    });

    test('rejects traversal and reserved platform filenames', () {
      final unsafeNames = [
        '../secret',
        r'folder\secret',
        'CON.txt',
        r'CONIN$',
        r'CONOUT$',
        r'CLOCK$',
        'COM1.log',
        'COM¹.log',
        'a:b',
      ];

      for (final name in unsafeNames) {
        expect(
          () => TransferFileEntry(name: name, size: 1),
          throwsFormatException,
          reason: name,
        );
      }
    });

    test('rejects control characters and oversized names', () {
      expect(
        () => TransferFileEntry(name: 'bad\nname', size: 1),
        throwsFormatException,
      );
      expect(
        () => TransferFileEntry(
          name: 'a' * (TransferManifest.maxFilenameBytes + 1),
          size: 1,
        ),
        throwsFormatException,
      );
    });

    test('rejects malformed batch IDs and sizes', () {
      expect(
        () => TransferManifest(
          batchId: [1],
          files: [
            TransferFileEntry(name: 'a', size: 1),
          ],
        ),
        throwsFormatException,
      );
      expect(
        () => TransferFileEntry(name: 'a', size: -1),
        throwsFormatException,
      );
    });

    test('rejects more than the maximum file count', () {
      expect(
        () => TransferManifest(
          batchId: List<int>.filled(16, 1),
          files: List<TransferFileEntry>.generate(
            TransferManifest.maxFiles + 1,
            (index) => TransferFileEntry(
              name: 'file-$index.bin',
              size: 0,
            ),
          ),
        ),
        throwsFormatException,
      );
    });

    test('rejects overflowing total batch size', () {
      expect(
        () => TransferManifest(
          batchId: List<int>.filled(16, 1),
          files: [
            TransferFileEntry(
              name: 'a.bin',
              size: TransferManifest.maxSafeFileSize,
            ),
            TransferFileEntry(name: 'b.bin', size: 1),
          ],
        ),
        throwsFormatException,
      );
    });

    test('rejects oversized manifest payload', () {
      expect(
        () => TransferManifest.decode(
          List<int>.filled(TransferManifest.maxManifestBytes + 1, 0),
        ),
        throwsFormatException,
      );
    });
  });
}
