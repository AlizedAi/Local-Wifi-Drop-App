import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_wifi_drop/main.dart';
import 'package:local_wifi_drop/src/app_log_controller.dart';
import 'package:local_wifi_drop/src/chat_store.dart';
import 'package:local_wifi_drop/src/local_peer_discovery.dart';

void main() {
  setUp(() => ChatStore.instance.clear());

  Future<void> pumpUntilHitTestable(WidgetTester tester, Finder finder) async {
    for (var attempt = 0; attempt < 20; attempt++) {
      if (finder.hitTestable().evaluate().isNotEmpty) return;
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(finder.hitTestable(), findsOneWidget);
  }

  testWidgets('app opens directly on the Send screen', (tester) async {
    await tester.pumpWidget(const LocalWifiDropApp());

    expect(find.text('Choose File'), findsOneWidget);
    expect(find.text('Destination IP'), findsNothing);
    expect(find.text('Enter IP manually'), findsNothing);
    expect(find.byKey(const ValueKey('send-destination-picker')), findsOneWidget);
    expect(find.byKey(const ValueKey('send-alerts-button')), findsOneWidget);
    expect(find.text('Message'), findsOneWidget);
    expect(find.text('Write Text'), findsNothing);
    final sendMessageField = tester.widget<TextField>(find.byKey(const ValueKey('send-message-field')));
    expect(sendMessageField.decoration?.hintText, 'Write message');
    expect(sendMessageField.style?.color, Colors.black);
    expect(find.byKey(const ValueKey('send-chat-transcript')), findsNothing);
    expect(find.byKey(const ValueKey('send-text-message')), findsOneWidget);
    expect(find.byKey(const ValueKey('paste-text-message')), findsOneWidget);
    expect(find.text('Send files'), findsNothing);
    expect(find.text('Receive files'), findsNothing);
  });

  testWidgets('Send screen does not use the Wi-Fi router gateway as its device IP', (tester) async {
    const channel = MethodChannel('local_wifi_drop/network');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      fail('The Send default IP must come from this device, not the router gateway.');
    });

    await tester.pumpWidget(const LocalWifiDropApp());
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('10.0.0.1'), findsNothing);
    expect(find.text('Select device'), findsNothing);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('peer picker shows the empty state when no message peers are found', (tester) async {
    const channel = MethodChannel('local_wifi_drop/network');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => <String>[]);
    await tester.pumpWidget(LocalWifiDropApp(
      messagePeerDiscovery: () async => <DiscoveredMessagePeer>[],
    ));
    await tester.pump();

    final field = find.byKey(const ValueKey('send-destination-picker'));
    await tester.tap(field);
    await tester.pump();

    final dropdown = find.byKey(const ValueKey('send-peer-dropdown'));
    expect(dropdown, findsOneWidget);
    expect(
      tester.getRect(dropdown).top,
      greaterThanOrEqualTo(tester.getRect(field).bottom),
    );
    expect(find.text('192.168.1.20'), findsNothing);
    expect(find.text('192.168.1.25'), findsNothing);
    expect(find.text('No responding devices found.'), findsOneWidget);
    expect(find.text('Only devices running Local WiFi Drop appear here.'), findsNothing);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('peer picker includes IPs returned by the native Wi-Fi subnet scan', (tester) async {
    const channel = MethodChannel('local_wifi_drop/network');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'scanWifiDevices');
      return <String>['192.168.1.31', '192.168.1.32'];
    });

    await tester.pumpWidget(LocalWifiDropApp(
      messagePeerDiscovery: () async => <DiscoveredMessagePeer>[
        const DiscoveredMessagePeer(address: '192.168.1.31', port: 39476),
      ],
    ));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('send-destination-picker')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('192.168.1.31'), findsOneWidget);
    expect(find.text('192.168.1.32'), findsOneWidget);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('incoming message is shared by Send and Receive and appears black', (tester) async {
    ChatStore.instance.clear();
    await tester.pumpWidget(const LocalWifiDropApp());
    ChatStore.instance.addIncoming('Incoming message for transcript', senderAddress: '192.168.1.25', deliveryId: 'widget-incoming-1');
    await tester.pump();
    expect(find.byKey(const ValueKey('send-chat-transcript')), findsOneWidget);
    final message = tester.widget<Text>(find.text('Incoming message for transcript'));
    expect(message.style?.color, Colors.black);
    await tester.tap(find.byKey(const ValueKey('send-header-receive-tab')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final receiveTranscript = find.byKey(const ValueKey('receive-chat-transcript'));
    expect(receiveTranscript, findsOneWidget);
    expect(find.descendant(of: receiveTranscript, matching: find.text('Incoming message for transcript')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('received-message-field')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(find.byKey(const ValueKey('received-message-field')), 'Reply from Receive');
    await tester.pump();
    final reply = tester.widget<FilledButton>(find.byKey(const ValueKey('receive-send-text-message')));
    expect(reply.onPressed, isNotNull);
    ChatStore.instance.clear();
  });

  testWidgets('both Message windows use the same selected peer IP', (tester) async {
    ChatStore.instance.selectPeer('192.168.1.20');
    await tester.pumpWidget(const LocalWifiDropApp());
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('send-destination-picker')),
        matching: find.text('192.168.1.20'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('send-header-receive-tab')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('received-message-field')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(
      find.byKey(const ValueKey('received-message-field')),
      'Message from Receive',
    );
    await tester.pump();
    final receiveSend = tester.widget<FilledButton>(
      find.byKey(const ValueKey('receive-send-text-message')),
    );
    expect(receiveSend.onPressed, isNotNull);
  });

  testWidgets('Send tab is left and Receive tab is right', (tester) async {
    await tester.pumpWidget(const LocalWifiDropApp());

    final send = tester.getTopLeft(find.byKey(const ValueKey('send-header-send-tab')));
    final receive = tester.getTopLeft(find.byKey(const ValueKey('send-header-receive-tab')));
    expect(send.dx, lessThan(receive.dx));

    await tester.tap(find.byKey(const ValueKey('send-header-receive-tab')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Start receiving'), findsNothing);
    expect(find.text('Choose a destination folder to start receiving.'), findsNothing);
    expect(find.byKey(const ValueKey('receive-sender-address')), findsOneWidget);
  });

  testWidgets('Receive uses compact sender and one-file display areas', (tester) async {
    await tester.pumpWidget(const LocalWifiDropApp());
    await tester.tap(find.byKey(const ValueKey('send-header-receive-tab')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('From'), findsOneWidget);
    expect(find.text('Start receiving'), findsNothing);
    expect(find.text('Choose a destination folder to start receiving.'), findsNothing);
    expect(find.byKey(const ValueKey('receive-alerts-button')), findsOneWidget);
    expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Open')).onPressed, isNull);
    expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Delete')).onPressed, isNull);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('received-files-list')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.widgetWithText(OutlinedButton, 'Open'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Delete'), findsOneWidget);
    expect(tester.getSize(find.byKey(const ValueKey('received-files-list'))).height, 56);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('received-message-field')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    final messageField = tester.widget<TextField>(find.byKey(const ValueKey('received-message-field')));
    expect(messageField.minLines, 3);
    expect(messageField.maxLines, 3);
    expect(messageField.readOnly, isFalse);
    expect(messageField.decoration?.hintText, 'Write message');
    expect(messageField.style?.color, Colors.black);
    expect(find.byKey(const ValueKey('receive-chat-transcript')), findsNothing);
    expect(find.text('Message'), findsOneWidget);
    expect(find.byKey(const ValueKey('receive-send-text-message')), findsOneWidget);
    expect(find.byKey(const ValueKey('receive-paste-text-message')), findsOneWidget);
    expect(find.text('Message Received'), findsNothing);
    expect(find.textContaining('localwifidrop://'), findsNothing);
  });

  testWidgets('three-dot options menu is 200 logical pixels wide and has no ON/OFF controls', (tester) async {
    await tester.pumpWidget(const LocalWifiDropApp());
    await tester.tap(find.byKey(const ValueKey('send-options-menu')));
    await tester.pump(const Duration(milliseconds: 300));

    final firstMenuItem = find.byType(PopupMenuItem<String>).first;
    expect(firstMenuItem, findsOneWidget);
    expect(tester.getSize(firstMenuItem).width, 200);
    expect(find.text('ON'), findsNothing);
    expect(find.text('OFF'), findsNothing);
  });

  testWidgets('Alert List opens below the header Alert button and is compact', (tester) async {
  await tester.pumpWidget(const LocalWifiDropApp());
  final button = find.byKey(const ValueKey('send-alerts-button'));
  expect(button, findsOneWidget);
  await tester.tap(button);
  await tester.pump(const Duration(milliseconds: 300));

  final panel = find.byKey(const ValueKey('action-list-panel'));
  expect(panel, findsOneWidget);
  expect(find.text('Alert List'), findsOneWidget);
  expect(find.text('ALERT · ACTION LIST'), findsNothing);
  expect(tester.getSize(panel).width, 180);
  expect(tester.getRect(panel).top, greaterThanOrEqualTo(tester.getRect(button).bottom));
  expect(tester.takeException(), isNull);
});

testWidgets('Options menu is compact, centers its section labels, and places languages below Languages', (tester) async {
  await tester.pumpWidget(const LocalWifiDropApp());
  await tester.tap(find.byKey(const ValueKey('send-options-menu')));
  await tester.pump(const Duration(milliseconds: 300));

  final alert = find.text('Alert');
  final log = find.text('Log');
  final languages = find.text('Languages');
  final en = find.text('EN');
  final fa = find.text('FA');
  expect(alert, findsOneWidget);
  expect(log, findsOneWidget);
  expect(languages, findsOneWidget);
  expect(en, findsOneWidget);
  expect(fa, findsOneWidget);

  expect(tester.getRect(en).top, greaterThan(tester.getRect(languages).bottom));
  expect(tester.getRect(fa).top, greaterThan(tester.getRect(languages).bottom));
  expect(tester.getRect(alert).center.dx, closeTo(tester.getRect(log).center.dx, 1));
  expect(tester.getRect(log).center.dx, closeTo(tester.getRect(languages).center.dx, 1));
  expect(tester.takeException(), isNull);
});

testWidgets('Options settings labels open their matching Android settings pages', (tester) async {
    const networkChannel = MethodChannel('local_wifi_drop/network');
    const storageChannel = MethodChannel('local_wifi_drop/storage');
    final calls = <String>[];

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(networkChannel, (call) async {
      calls.add(call.method);
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(storageChannel, (call) async {
      calls.add(call.method);
      return null;
    });

    await tester.pumpWidget(const LocalWifiDropApp());

    const labelKeys = {
      'Wi-Fi': ValueKey('options-wifi-label'),
      'Notifications': ValueKey('options-notifications-label'),
      'Storage': ValueKey('options-storage-label'),
    };

    Future<void> openAndTap(String label) async {
      await tester.tap(find.byKey(const ValueKey('send-options-menu')));
      await tester.pump(const Duration(milliseconds: 500));
      final labelFinder = find.byKey(labelKeys[label]!);
      expect(labelFinder, findsOneWidget);
      await pumpUntilHitTestable(tester, labelFinder);
      await tester.tap(labelFinder);
      await tester.pump(const Duration(milliseconds: 500));
    }

    await openAndTap('Wi-Fi');
    await openAndTap('Notifications');
    await openAndTap('Storage');

    expect(calls, [
      'openWifiSettings',
      'openNotificationSettings',
      'openStorageSettings',
    ]);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(networkChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(storageChannel, null);
  });


testWidgets('Log panel is 200 pixels wide, anchored to Log, and stops above the main Send button', (tester) async {
  await tester.pumpWidget(const LocalWifiDropApp());
  await tester.tap(find.byKey(const ValueKey('send-options-menu')));
  await tester.pump(const Duration(milliseconds: 500));

  final logLabel = find.text('Log');
  final logRect = tester.getRect(logLabel);
  final optionsMenuRect = tester.getRect(find.byType(PopupMenuItem<String>).first);

  await pumpUntilHitTestable(tester, logLabel);
  await tester.tap(logLabel);
  await tester.pump(const Duration(milliseconds: 300));

  final panel = find.byKey(const ValueKey('log-panel-overlay'));
  expect(panel, findsOneWidget);
  final panelRect = tester.getRect(panel);
  final sendRect = tester.getRect(find.byKey(const ValueKey('bottom-send-button')));

  expect(panelRect.width, 200);
  expect(panelRect.top, closeTo(logRect.top, 1));
  expect(panelRect.bottom, lessThanOrEqualTo(sendRect.top - 7));
  expect(panelRect.right, closeTo(optionsMenuRect.left - 8, 2));
  expect(find.byTooltip('Copy selected'), findsOneWidget);
  expect(find.byTooltip('Copy all'), findsNothing);
  expect(find.byTooltip('Clear log'), findsOneWidget);
  expect(tester.takeException(), isNull);
});


  
testWidgets('Log opens from the Receive screen Options menu', (tester) async {
  await tester.pumpWidget(const LocalWifiDropApp());
  await tester.tap(find.byKey(const ValueKey('send-header-receive-tab')));
  await tester.pump(const Duration(milliseconds: 300));

  await tester.tap(find.byKey(const ValueKey('receive-options-menu')));
  await tester.pump(const Duration(milliseconds: 500));
  final logLabel = find.text('Log');
  await pumpUntilHitTestable(tester, logLabel);
  await tester.tap(logLabel);
  await tester.pump(const Duration(milliseconds: 300));

  expect(find.byKey(const ValueKey('log-panel-overlay')), findsOneWidget);
  expect(find.byTooltip('Clear log'), findsOneWidget);
  expect(tester.takeException(), isNull);
});

testWidgets('Log text is one continuous selectable area across entries', (tester) async {
    String? clipboardText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboardText = (call.arguments as Map?)?['text'] as String?;
        return null;
      }
      if (call.method == 'Clipboard.getData') {
        return clipboardText == null ? null : <String, dynamic>{'text': clipboardText};
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
      AppLogController.instance.clear();
    });

    AppLogController.instance.clear();
    AppLogController.instance.record('TEST', 'First selectable log entry');
    AppLogController.instance.record('TEST', 'Second selectable log entry');

    await tester.pumpWidget(const LocalWifiDropApp());
    await tester.tap(find.byKey(const ValueKey('send-options-menu')));
    await tester.pump(const Duration(milliseconds: 500));
    final logLabel = find.text('Log');
    await pumpUntilHitTestable(tester, logLabel);
    await tester.tap(logLabel);
    await tester.pump(const Duration(milliseconds: 500));

    final panel = find.byKey(const ValueKey('log-panel-overlay'));
    final selectable = find.descendant(
      of: panel,
      matching: find.byType(SelectableText),
    );
    expect(selectable, findsOneWidget);
    final textWidget = tester.widget<SelectableText>(selectable);
    final allLogText = textWidget.textSpan!.toPlainText();
    expect(allLogText, contains('First selectable log entry'));
    expect(allLogText, contains('Second selectable log entry'));
    expect(allLogText, contains('\n'));

    // Drive the SelectableText selection callback directly. This isolates
    // the header Copy behavior from platform-specific selection toolbars.
    final selectedText = 'First selectable log entry';
    final selectionStart = allLogText.indexOf(selectedText);
    expect(selectionStart, greaterThanOrEqualTo(0));
    textWidget.onSelectionChanged!(
      TextSelection(
        baseOffset: selectionStart,
        extentOffset: selectionStart + selectedText.length,
      ),
      SelectionChangedCause.longPress,
    );
    await tester.pump();

    final copyButton = find.byKey(const ValueKey('log-copy-button'));
    expect(copyButton, findsOneWidget);
    final copyAction = tester.widget<IconButton>(copyButton).onPressed;
    expect(copyAction, isNotNull);

    await tester.tap(copyButton);
    await tester.pump(const Duration(milliseconds: 200));
    final copied = await Clipboard.getData(Clipboard.kTextPlain);
    expect(copied?.text, selectedText);
    expect(clipboardText, selectedText);
  });

}
