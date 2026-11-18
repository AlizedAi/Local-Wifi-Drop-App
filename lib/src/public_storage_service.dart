import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// Publishes completed transfers and app information into shared Documents.
/// Android uses MediaStore so this works with scoped storage without
/// requesting broad "all files" access. Other platforms keep their own flow.
class PublicStorageService {
  PublicStorageService._();

  static final PublicStorageService instance = PublicStorageService._();
  static const MethodChannel _channel = MethodChannel('local_wifi_drop/storage');

  Future<String> getStagingDirectory() async {
    final path = await _channel.invokeMethod<String>('getStagingDirectory');
    if (path == null || path.isEmpty) {
      throw StateError('Could not prepare the receive staging directory.');
    }
    final directory = Directory(path);
    await directory.create(recursive: true);
    return path;
  }

  Future<void> publishReceivedFile(File file) async {
    await _channel.invokeMethod<void>('publishReceivedFile', {
      'sourcePath': file.path,
      'fileName': file.uri.pathSegments.isEmpty
          ? file.uri.path
          : file.uri.pathSegments.last,
    });
  }

  Future<void> openReceivedFolder() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<bool>('openReceivedFolder');
  }

  Future<void> writeInfoFile({
    required String subfolder,
    required String fileName,
    required String content,
  }) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('writeInfoFile', {
      'subfolder': subfolder,
      'fileName': fileName,
      'content': content,
    });
  }

  Future<void> writeJson({
    required String subfolder,
    required String fileName,
    required Object value,
  }) =>
      writeInfoFile(
        subfolder: subfolder,
        fileName: fileName,
        content: const JsonEncoder.withIndent('  ').convert(value),
      );
}
