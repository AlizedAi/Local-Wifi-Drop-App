import 'dart:io';

import 'package:flutter/services.dart';

/// Publishes only completed received files into shared Documents.
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

  Future<String> publishReceivedFile(File file) async {
    final uri = await _channel.invokeMethod<String>('publishReceivedFile', {
      'sourcePath': file.path,
      'fileName': file.uri.pathSegments.isEmpty
          ? file.uri.path
          : file.uri.pathSegments.last,
    });
    if (uri == null || uri.isEmpty) {
      throw StateError('Android did not return the saved file location.');
    }
    return uri;
  }

  Future<void> deleteReceivedFile({
    required File file,
    String? publishedUri,
  }) async {
    if (Platform.isAndroid && publishedUri != null) {
      await _channel.invokeMethod<void>('deleteReceivedFile', {
        'uri': publishedUri,
        'sourcePath': file.path,
      });
      return;
    }
    if (await file.exists()) await file.delete();
  }

  Future<void> openReceivedFolder() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<bool>('openReceivedFolder');
  }
}
