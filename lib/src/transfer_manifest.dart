import 'dart:convert';
import 'dart:typed_data';

class TransferFileEntry {
  factory TransferFileEntry({required String name, required int size}) {
    _validateDisplayName(name);
    if (size < 0 || size > TransferManifest.maxSafeFileSize) throw const FormatException('File size is outside the allowed range.');
    return TransferFileEntry._(name: name, size: size);
  }
  const TransferFileEntry._({required this.name, required this.size});
  final String name;
  final int size;
}

/// Manifest carries names and sizes only. FILE_END carries the streaming digest.
class TransferManifest {
  factory TransferManifest({required List<int> batchId, required List<TransferFileEntry> files}) {
    if (batchId.length != batchIdBytes || batchId.any((b) => b < 0 || b > 255)) throw const FormatException('Batch ID must contain exactly 16 bytes.');
    if (files.isEmpty || files.length > maxFiles) throw const FormatException('Manifest file count is invalid.');
    _validateUniqueNames(files);
    var total = 0;
    for (final file in files) {
      if (file.size > maxSafeFileSize - total) throw const FormatException('Total batch size is outside the allowed range.');
      total += file.size;
    }
    final result = TransferManifest._(batchId: List<int>.unmodifiable(batchId), files: List<TransferFileEntry>.unmodifiable(files));
    result._encodedLength();
    return result;
  }
  const TransferManifest._({required this.batchId, required this.files});
  static const int schemaVersion = 1;
  static const int batchIdBytes = 16;
  static const int maxFiles = 100;
  static const int maxManifestBytes = 256 * 1024;
  static const int maxFilenameBytes = 255;
  static const int maxSafeFileSize = 0x7fffffffffffffff;
  static const int _fixedHeaderBytes = 19;
  static const int _fixedEntryBytes = 10;
  final List<int> batchId;
  final List<TransferFileEntry> files;
  int get totalBytes => files.fold<int>(0, (sum, file) => sum + file.size);
  Uint8List encode() {
    final output = Uint8List(_encodedLength());
    final data = ByteData.sublistView(output);
    var offset = 0;
    output[offset++] = schemaVersion;
    output.setRange(offset, offset + batchIdBytes, batchId);
    offset += batchIdBytes;
    data.setUint16(offset, files.length, Endian.big);
    offset += 2;
    for (final file in files) {
      final name = utf8.encode(file.name);
      data.setUint16(offset, name.length, Endian.big);
      offset += 2;
      output.setRange(offset, offset + name.length, name);
      offset += name.length;
      data.setUint64(offset, file.size, Endian.big);
      offset += 8;
    }
    return output;
  }
  static TransferManifest decode(List<int> payload) {
    if (payload.length < _fixedHeaderBytes || payload.length > maxManifestBytes) throw const FormatException('Manifest length is invalid.');
    if (payload.any((b) => b < 0 || b > 255)) throw const FormatException('Manifest contains an invalid byte.');
    final bytes = Uint8List.fromList(payload);
    final data = ByteData.sublistView(bytes);
    var offset = 0;
    if (bytes[offset++] != schemaVersion) throw const FormatException('Unsupported manifest version.');
    final batchId = bytes.sublist(offset, offset + batchIdBytes);
    offset += batchIdBytes;
    final count = data.getUint16(offset, Endian.big);
    offset += 2;
    if (count == 0 || count > maxFiles) throw const FormatException('Manifest file count is invalid.');
    final files = <TransferFileEntry>[];
    for (var i = 0; i < count; i++) {
      if (bytes.length - offset < 2) throw const FormatException('Manifest ended inside a filename length.');
      final nameLength = data.getUint16(offset, Endian.big);
      offset += 2;
      if (nameLength == 0 || nameLength > maxFilenameBytes || bytes.length - offset < nameLength + 8) throw const FormatException('Manifest file entry length is invalid.');
      final nameBytes = bytes.sublist(offset, offset + nameLength);
      offset += nameLength;
      late final String name;
      try { name = utf8.decode(nameBytes, allowMalformed: false); }
      on FormatException { throw const FormatException('Filename is not valid UTF-8.'); }
      if ((bytes[offset] & 0x80) != 0) throw const FormatException('File size is outside the allowed range.');
      final size = data.getUint64(offset, Endian.big);
      offset += 8;
      files.add(TransferFileEntry(name: name, size: size));
    }
    if (offset != bytes.length) throw const FormatException('Manifest contains trailing bytes.');
    return TransferManifest(batchId: batchId, files: files);
  }
  int _encodedLength() {
    var length = _fixedHeaderBytes;
    for (final file in files) {
      final nameLength = utf8.encode(file.name).length;
      if (nameLength == 0 || nameLength > maxFilenameBytes) throw const FormatException('Filename length is invalid.');
      length += _fixedEntryBytes + nameLength;
      if (length > maxManifestBytes) throw const FormatException('Manifest is too large.');
    }
    return length;
  }
  static void _validateUniqueNames(List<TransferFileEntry> files) {
    final names = <String>{};
    for (final file in files) {
      if (!names.add(file.name.toLowerCase())) throw const FormatException('Manifest contains duplicate filenames.');
    }
  }
}
void _validateDisplayName(String name) {
  if (name.isEmpty || name == '.' || name == '..') throw const FormatException('Filename is empty or reserved.');
  if (utf8.encode(name).length > TransferManifest.maxFilenameBytes) throw const FormatException('Filename is too long.');
  if (name.contains('/') || name.contains(String.fromCharCode(92)) || name.contains(':') || name.endsWith('.') || name.endsWith(' ')) throw const FormatException('Filename contains an unsafe path character.');
  for (final rune in name.runes) {
    if (rune <= 0x1f || (rune >= 0x7f && rune <= 0x9f) || (rune >= 0x202a && rune <= 0x202e) || (rune >= 0x2066 && rune <= 0x2069)) throw const FormatException('Filename contains a control character.');
  }
  final stem = name.split('.').first.trim().toUpperCase();
  const reserved = {'CON','PRN','AUX','NUL',r'CONIN$',r'CONOUT$',r'CLOCK$'};
  if (reserved.contains(stem) || RegExp(r'^(COM|LPT)[1-9¹²³]$').hasMatch(stem)) throw const FormatException('Filename is reserved on a target platform.');
}
