import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_wifi_drop/src/chat_transcript.dart';

void main() {
  testWidgets('delivered outgoing text is green and incoming text is black',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatTranscript(
            messages: [
              ChatMessage(
                id: 1,
                text: 'Delivered outgoing',
                isOutgoing: true,
                isDelivered: true,
              ),
              ChatMessage(
                id: 2,
                text: 'Incoming message',
                isOutgoing: false,
                isDelivered: true,
              ),
            ],
          ),
        ),
      ),
    );

    final outgoing = tester.widget<Text>(find.text('Delivered outgoing'));
    final incoming = tester.widget<Text>(find.text('Incoming message'));
    expect(outgoing.style?.color, const Color(0xFF159447));
    expect(incoming.style?.color, Colors.black);
  });

  testWidgets('outgoing text stays black until delivery is acknowledged',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatTranscript(
            messages: [
              ChatMessage(
                id: 1,
                text: 'Waiting for acknowledgement',
                isOutgoing: true,
              ),
            ],
          ),
        ),
      ),
    );

    final pending = tester.widget<Text>(
      find.text('Waiting for acknowledgement'),
    );
    expect(pending.style?.color, Colors.black);
  });

  testWidgets('outgoing bubbles are on the left and incoming bubbles are on the right',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatTranscript(
            messages: [
              ChatMessage(id: 1, text: 'Outgoing', isOutgoing: true),
              ChatMessage(id: 2, text: 'Incoming', isOutgoing: false),
            ],
          ),
        ),
      ),
    );

    final outgoingAlign = tester.widget<Align>(
      find.ancestor(of: find.text('Outgoing'), matching: find.byType(Align)).first,
    );
    final incomingAlign = tester.widget<Align>(
      find.ancestor(of: find.text('Incoming'), matching: find.byType(Align)).first,
    );
    expect(outgoingAlign.alignment, Alignment.centerLeft);
    expect(incomingAlign.alignment, Alignment.centerRight);
  });

}
