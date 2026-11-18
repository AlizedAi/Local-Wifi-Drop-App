import 'package:flutter/foundation.dart';
import 'chat_transcript.dart';

/// One in-memory conversation shared by the Send and Receive screens.
class ChatStore extends ChangeNotifier {
  ChatStore._();
  static final ChatStore instance = ChatStore._();
  static const int maxMessages = 10;
  final List<ChatMessage> _messages = [];
  final Set<String> _seenDeliveryIds = {};
  int _nextId = 0;
  String? _lastIncomingSenderAddress;
  String? _selectedPeerAddress;

  List<ChatMessage> get messages => List<ChatMessage>.unmodifiable(_messages);
  String? get lastIncomingSenderAddress => _lastIncomingSenderAddress;
  String? get selectedPeerAddress => _selectedPeerAddress;

  void selectPeer(String? address) {
    final normalized = address?.trim();
    final next = normalized == null || normalized.isEmpty ? null : normalized;
    if (_selectedPeerAddress == next) return;
    _selectedPeerAddress = next;
    notifyListeners();
  }

  ChatMessage addOutgoing(String text, {bool isDelivered = false}) {
    final message = ChatMessage(id: ++_nextId, text: text, isOutgoing: true, isDelivered: isDelivered);
    _append(message);
    return message;
  }

  ChatMessage? addIncoming(String text, {String? senderAddress, String? deliveryId}) {
    if (deliveryId != null && !_seenDeliveryIds.add(deliveryId)) return null;
    if (deliveryId != null && _seenDeliveryIds.length > 300) _seenDeliveryIds.remove(_seenDeliveryIds.first);
    if (senderAddress != null && senderAddress.isNotEmpty) {
      _lastIncomingSenderAddress = senderAddress;
      _selectedPeerAddress = senderAddress;
    }
    final message = ChatMessage(id: ++_nextId, text: text, isOutgoing: false, isDelivered: true);
    _append(message);
    return message;
  }

  void markDelivered(int id) {
    final index = _messages.indexWhere((message) => message.id == id);
    if (index < 0 || _messages[index].isDelivered) return;
    _messages[index] = _messages[index].copyWith(isDelivered: true);
    notifyListeners();
  }

  void remove(int id) {
    final length = _messages.length;
    _messages.removeWhere((message) => message.id == id);
    if (_messages.length != length) notifyListeners();
  }

  void clear() {
    _messages.clear();
    _seenDeliveryIds.clear();
    _lastIncomingSenderAddress = null;
    _selectedPeerAddress = null;
    notifyListeners();
  }

  void _append(ChatMessage message) {
    _messages.add(message);
    if (_messages.length > maxMessages) _messages.removeRange(0, _messages.length - maxMessages);
    notifyListeners();
  }
}
