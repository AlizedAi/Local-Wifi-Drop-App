import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_wifi_drop/src/transfer_alert.dart';
import 'package:local_wifi_drop/src/transfer_alert_controller.dart';
import 'package:local_wifi_drop/src/transfer_history_panel.dart';

void main() {
  testWidgets('action list keeps its shell without inner cards', (tester) async {
    final controller = TransferAlertController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: TransferHistoryPanel(controller: controller))));

    expect(find.text('Alert List'), findsOneWidget);
    expect(find.text('↑  SEND DATA'), findsNothing);
    expect(find.text('↓  RECEIVE DATA'), findsNothing);
    expect(find.text('No activity yet'), findsNothing);
    expect(find.byKey(const ValueKey('send-action-section')), findsNothing);
    expect(find.byKey(const ValueKey('receive-action-section')), findsNothing);
    final panelSize = tester.getSize(find.byKey(const ValueKey('action-list-panel')));
    expect(panelSize.width, 180);
    expect(panelSize.height, 344);
  });

  testWidgets('transfer records remain hidden while inner cards are removed', (tester) async {
    final controller = TransferAlertController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: TransferHistoryPanel(controller: controller))));

    controller.add(const TransferAlert(fileName: 'sent.jpg', status: TransferAlertStatus.sent, direction: TransferDirection.send));
    controller.add(const TransferAlert(fileName: 'failed.pdf', status: TransferAlertStatus.failed, direction: TransferDirection.send));
    controller.add(const TransferAlert(fileName: 'received.mp3', status: TransferAlertStatus.received, direction: TransferDirection.receive));
    await tester.pump();

    expect(find.text('sent.jpg'), findsNothing);
    expect(find.text('failed.pdf'), findsNothing);
    expect(find.text('received.mp3'), findsNothing);
    expect(find.text('DONE'), findsNothing);
    expect(find.text('FAIL'), findsNothing);
    expect(find.text('↑  SEND DATA'), findsNothing);
    expect(find.text('↓  RECEIVE DATA'), findsNothing);
  });

  testWidgets('clear history removes all action list records', (tester) async {
    final controller = TransferAlertController();
    controller.add(const TransferAlert(fileName: 'B.MP3', status: TransferAlertStatus.sent));
    addTearDown(controller.dispose);

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: TransferHistoryPanel(controller: controller))));
    await tester.tap(find.byTooltip('Clear history'));
    await tester.pump();

    expect(controller.items, isEmpty);
    expect(find.text('B.MP3'), findsNothing);
    expect(find.text('No activity yet'), findsNothing);
  });
}
