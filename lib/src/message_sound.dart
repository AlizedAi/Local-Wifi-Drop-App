import 'package:flutter/services.dart';

/// Plays short native Android tones after successful message delivery.
class MessageSound {
  static const MethodChannel _channel = MethodChannel('local_wifi_drop/sound');

  static Future<void> playSent() => _play('playSent');

  static Future<void> playReceived() => _play('playReceived');

  static Future<void> _play(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } on PlatformException {
      // A sound failure must never change message delivery success.
    } on MissingPluginException {
      // Non-Android targets and tests may not provide the native sound channel.
    }
  }
}
