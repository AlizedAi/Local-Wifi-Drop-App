import 'package:flutter_test/flutter_test.dart';
import 'package:local_wifi_drop/src/background_message_delivery.dart';

void main() {
  group('BackgroundMessageDelivery', () {
    test('persists before ACCEPT and then hands off to UI and notification', () async {
      final events = <String>[];
      final delivery = BackgroundMessageDelivery(
        persist: () async {
          events.add('persist');
          return 'message-42';
        },
        acknowledge: () async {
          events.add('accept');
        },
        notifyMain: (id) => events.add('main:$id'),
        showNotification: (id) async => events.add('notification:$id'),
      );

      expect(await delivery.deliver(), 'message-42');
      expect(events, [
        'persist',
        'accept',
        'main:message-42',
        'notification:message-42',
      ]);
    });

    test('does not acknowledge or notify when persistence fails', () async {
      final events = <String>[];
      final delivery = BackgroundMessageDelivery(
        persist: () async {
          events.add('persist');
          throw StateError('storage failed');
        },
        acknowledge: () async => events.add('accept'),
        notifyMain: (_) => events.add('main'),
        showNotification: (_) async => events.add('notification'),
      );

      await expectLater(delivery.deliver(), throwsA(isA<StateError>()));
      expect(events, ['persist']);
    });

    test('does not hand off notifications when ACCEPT fails', () async {
      final events = <String>[];
      final delivery = BackgroundMessageDelivery(
        persist: () async {
          events.add('persist');
          return 'message-43';
        },
        acknowledge: () async {
          events.add('accept');
          throw StateError('socket closed');
        },
        notifyMain: (_) => events.add('main'),
        showNotification: (_) async => events.add('notification'),
      );

      await expectLater(delivery.deliver(), throwsA(isA<StateError>()));
      expect(events, ['persist', 'accept']);
    });
  });
}
