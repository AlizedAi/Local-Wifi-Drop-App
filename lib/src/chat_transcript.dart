import 'package:flutter/material.dart';

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.text,
    required this.isOutgoing,
    this.isDelivered = false,
  });

  final int id;
  final String text;
  final bool isOutgoing;
  final bool isDelivered;

  ChatMessage copyWith({bool? isDelivered}) => ChatMessage(
        id: id,
        text: text,
        isOutgoing: isOutgoing,
        isDelivered: isDelivered ?? this.isDelivered,
      );
}

class ChatTranscript extends StatelessWidget {
  const ChatTranscript({super.key, required this.messages});

  final List<ChatMessage> messages;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FBF8),
        borderRadius: BorderRadius.circular(10),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 140),
        child: ListView.builder(
          shrinkWrap: true,
          reverse: true,
          itemCount: messages.length,
          itemBuilder: (context, reverseIndex) {
            final message = messages[messages.length - 1 - reverseIndex];
            final deliveredOutgoing = message.isOutgoing && message.isDelivered;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Align(
                alignment: message.isOutgoing
                    ? Alignment.centerLeft
                    : Alignment.centerRight,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 300),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: message.isOutgoing
                          ? const Color(0xFFEAF7EE)
                          : const Color(0xFFF0F3F1),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 7,
                      ),
                      child: Text(
                        message.text,
                        style: TextStyle(
                          color: deliveredOutgoing
                              ? const Color(0xFF159447)
                              : Colors.black,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
