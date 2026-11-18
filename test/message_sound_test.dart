import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_wifi_drop/src/message_sound.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('successful sends and receives request their distinct native tones', () async {
    const channel = MethodChannel('local_wifi_drop/sound');
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return true;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    await MessageSound.playSent();
    await MessageSound.playReceived();

    expect(calls, ['playSent', 'playReceived']);
  });
}
