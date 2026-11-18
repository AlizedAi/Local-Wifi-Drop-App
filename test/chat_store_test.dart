import 'package:flutter_test/flutter_test.dart';
import 'package:local_wifi_drop/src/chat_store.dart';

void main() {
  group('ChatStore', () {
    setUp(() => ChatStore.instance.clear());

    test('one conversation is shared and keeps the latest sender for replies', () {
      final changes = <int>[];
      void listener() => changes.add(ChatStore.instance.messages.length);
      ChatStore.instance.addListener(listener);
      final incoming = ChatStore.instance.addIncoming(
        'hello',
        senderAddress: '192.168.1.20',
        deliveryId: 'incoming-1',
      );
      final outgoing = ChatStore.instance.addOutgoing('reply');

      expect(ChatStore.instance.messages, hasLength(2));
      expect(ChatStore.instance.messages.first, same(incoming));
      expect(ChatStore.instance.messages.last, same(outgoing));
      expect(ChatStore.instance.lastIncomingSenderAddress, '192.168.1.20');
      expect(ChatStore.instance.selectedPeerAddress, '192.168.1.20');
      expect(changes, [1, 2]);
      ChatStore.instance.removeListener(listener);
    });

    test('selected peer is shared and can be changed from either Message window', () {
      ChatStore.instance.selectPeer('192.168.1.22');
      expect(ChatStore.instance.selectedPeerAddress, '192.168.1.22');
      ChatStore.instance.selectPeer('192.168.1.23');
      expect(ChatStore.instance.selectedPeerAddress, '192.168.1.23');
    });

    test('replayed persisted delivery IDs do not duplicate messages', () {
      ChatStore.instance.addIncoming(
        'once',
        senderAddress: '192.168.1.21',
        deliveryId: 'stable-id',
      );
      final duplicate = ChatStore.instance.addIncoming(
        'once',
        senderAddress: '192.168.1.21',
        deliveryId: 'stable-id',
      );

      expect(duplicate, isNull);
      expect(ChatStore.instance.messages, hasLength(1));
    });

    test('keeps only the latest 10 conversation entries', () {
      for (var i = 0; i < 35; i++) {
        ChatStore.instance.addOutgoing('message-$i');
      }
      expect(ChatStore.instance.messages, hasLength(10));
      expect(ChatStore.instance.messages.first.text, 'message-25');
      expect(ChatStore.instance.messages.last.text, 'message-34');
    });
  });
}
