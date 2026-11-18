import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_log_panel.dart';
import 'app_log_controller.dart';
import 'app_language_controller.dart';
import 'transfer_alert_controller.dart';

/// Shared visual header for the Send and Receive pages.
final GlobalKey _sendAlertButtonKey = GlobalKey();
final GlobalKey _receiveAlertButtonKey = GlobalKey();
final GlobalKey _logMenuItemKey = GlobalKey();
final GlobalKey _logMenuLabelKey = GlobalKey();
final GlobalKey<PopupMenuButtonState<String>> _sendOptionsMenuKey = GlobalKey();
final GlobalKey<PopupMenuButtonState<String>> _receiveOptionsMenuKey = GlobalKey();

class _PersistentPopupMenuEntry extends PopupMenuEntry<String> {
  const _PersistentPopupMenuEntry({
    super.key,
    required this.value,
    required this.child,
    required this.onTap,
    this.entryHeight = 40,
  });

  final String value;
  final Widget child;
  final VoidCallback onTap;
  final double entryHeight;

  @override
  double get height => entryHeight;

  @override
  bool represents(String? value) => this.value == value;

  @override
  State<_PersistentPopupMenuEntry> createState() =>
      _PersistentPopupMenuEntryState();
}

class _PersistentPopupMenuEntryState extends State<_PersistentPopupMenuEntry> {
  @override
  Widget build(BuildContext context) => SizedBox(
        height: widget.entryHeight,
        child: InkWell(onTap: widget.onTap, child: widget.child),
      );
}

class SendHeader extends StatelessWidget {
  const SendHeader({
    required this.onReceiveTap,
    required this.onSendTap,
    this.isReceive = false,
    this.alertsPanel,
    this.alertController,
    this.logPanelBottomKey,
    super.key,
  });

  final VoidCallback onReceiveTap;
  final VoidCallback onSendTap;
  final bool isReceive;
  final Widget? alertsPanel;
  final TransferAlertController? alertController;
  final GlobalKey? logPanelBottomKey;

  static const Color _darkGreen = Color(0xFF073B20);
  static const Color _brightGreen = Color(0xFF20D65A);
  static const Color _menuBackground = Color(0xFF242424);

  Widget _tab({
    required String label,
    required IconData icon,
    required bool active,
    required VoidCallback onTap,
    required Key key,
  }) {
    return Material(
      color: active ? Colors.white : Colors.transparent,
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        key: key,
        borderRadius: BorderRadius.circular(11),
        onTap: active ? null : onTap,
        child: Column(
          children: [
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: active ? Colors.black : Colors.white, size: 17),
                  const SizedBox(width: 7),
                  Text(
                    label,
                    style: TextStyle(
                      color: active ? Colors.black : Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            if (active)
              Container(
                height: 3,
                margin: const EdgeInsets.symmetric(horizontal: 24),
                decoration: BoxDecoration(
                  color: _brightGreen,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
          ],
        ),
      ),
    );
  }

  PopupMenuItem<String> _menuItem(
    String value,
    Widget child, {
    double height = 44,
    VoidCallback? onTap,
  }) {
    return PopupMenuItem<String>(
      value: value,
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      onTap: onTap,
      child: child,
    );
  }

  Widget _menuText(String value, {bool bold = false, double size = 17, Key? key}) {
    return Text(
      value,
      key: key,
      style: TextStyle(
        color: Colors.white,
        fontSize: size,
        fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
      ),
    );
  }

  Widget _wifiRow() => Center(
        child: _menuText('Wi-Fi', bold: true, size: 22, key: const ValueKey('options-wifi-label')),
      );

  Widget _notificationRow() => Center(
        child: _menuText('Notifications', bold: true, size: 22, key: const ValueKey('options-notifications-label')),
      );

  Widget _storageRow() => Center(
        child: _menuText('Storage', bold: true, size: 22, key: const ValueKey('options-storage-label')),
      );

  Widget _languageRow() {
    return ValueListenableBuilder<String>(
      valueListenable: AppLanguageController.instance.language,
      builder: (context, selectedLanguage, _) {
        Widget languageOption(String code, String value) {
          final active = selectedLanguage == value;
          return InkWell(
            key: ValueKey('language-option-$value'),
            borderRadius: BorderRadius.circular(5),
            onTap: () {
              AppLanguageController.instance.select(value);
              AppLogController.instance.record(
                'SETTINGS',
                'Display language selected: $value',
              );
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
              child: Text(
                code,
                style: TextStyle(
                  color: active ? const Color(0xFF20D65A) : Colors.white,
                  fontSize: 16,
                  fontWeight: active ? FontWeight.w800 : FontWeight.w500,
                ),
              ),
            ),
          );
        }

        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Center(child: _menuText('Languages', bold: true, size: 17)),
            const SizedBox(height: 2),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                languageOption('EN', AppLanguageController.english),
                const SizedBox(width: 20),
                languageOption('FA', AppLanguageController.persian),
                const SizedBox(width: 2),
              ],
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    var menuOpen = false;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 52,
          child: Stack(
            alignment: Alignment.center,
            children: [
              const Center(
                child: Text(
                  'Local Wi-Fi Drop',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 23,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.1,
                  ),
                ),
              ),
              if (alertsPanel != null)
                Positioned(
                  left: 0,
                  child: _AlertDropdownButton(
                    key: isReceive ? _receiveAlertButtonKey : _sendAlertButtonKey,
                    panel: alertsPanel!,
                    alertController: alertController,
                  ),
                ),
              Positioned(
                right: 0,
                child: StatefulBuilder(
                  builder: (context, setMenuState) {
                    return KeyedSubtree(
                      key: ValueKey(isReceive ? 'receive-options-menu' : 'send-options-menu'),
                      child: PopupMenuButton<String>(
                  key: isReceive ? _receiveOptionsMenuKey : _sendOptionsMenuKey,
                  tooltip: 'Options',
                  position: PopupMenuPosition.under,
                  offset: const Offset(0, 7),
                  color: _menuBackground,
                  surfaceTintColor: Colors.transparent,
                  elevation: 10,
                  constraints: const BoxConstraints(minWidth: 200, maxWidth: 200),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                  padding: EdgeInsets.zero,
                  icon: Icon(Icons.more_vert, color: menuOpen ? Colors.red : _brightGreen, size: 27),
                  onOpened: () {
                    AppLogController.instance.record('UI', 'Options menu opened');
                    setMenuState(() => menuOpen = true);
                  },
                  onCanceled: () {
                    AppLogController.instance.record('UI', 'Options menu dismissed without selection');
                    _AlertDropdownButton.closeLogPanel();
                    setMenuState(() => menuOpen = false);
                  },
                  onSelected: (value) {
                    AppLogController.instance.record('UI', 'Options menu item selected: $value');
                    setMenuState(() => menuOpen = false);
                    _AlertDropdownButton.closeLogPanel();
                    if (value == 'exit') {
                      SystemNavigator.pop();
                    }
                    // Settings destinations are handled by each item's onTap callback.
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem<String>(
                      value: 'alert',
                      height: 40,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      onTap: () {
                        if (alertsPanel != null) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            _AlertDropdownButton.showPanel(
                              context,
                              isReceive ? _receiveAlertButtonKey : _sendAlertButtonKey,
                              alertsPanel!,
                            );
                          });
                        }
                      },
                      child: Center(
                        child: _menuText('Alert', bold: true, size: 18),
                      ),
                    ),
                    _PersistentPopupMenuEntry(
                      key: _logMenuItemKey,
                      entryHeight: 40,
                      value: 'log',
                      onTap: () {
                        AppLogController.instance.record('UI', 'Log option selected');
                        _AlertDropdownButton.showLogPanel(
                          context,
                          _logMenuItemKey,
                          _logMenuLabelKey,
                          logPanelBottomKey,
                        );
                      },
                      child: Center(
                        child: Text(
                          'Log',
                          key: _logMenuLabelKey,
                          style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                    _menuItem('languages', _languageRow(), height: 64),
                    _menuItem(
                      'wifi',
                      _wifiRow(),
                      height: 42,
                      onTap: () async {
                        AppLogController.instance.record(
                          'SETTINGS',
                          'Opening Android Wi-Fi settings',
                        );
                        try {
                          await const MethodChannel('local_wifi_drop/network')
                              .invokeMethod<void>('openWifiSettings');
                        } on PlatformException catch (error) {
                          AppLogController.instance.record(
                            'ERROR',
                            'Could not open Wi-Fi settings: ${error.message ?? error.code}',
                          );
                        }
                      },
                    ),
                    _menuItem(
                      'notifications',
                      _notificationRow(),
                      height: 42,
                      onTap: () async {
                        AppLogController.instance.record(
                          'SETTINGS',
                          'Opening Android app notification settings',
                        );
                        try {
                          await const MethodChannel('local_wifi_drop/network')
                              .invokeMethod<void>('openNotificationSettings');
                        } on PlatformException catch (error) {
                          AppLogController.instance.record(
                            'ERROR',
                            'Could not open notification settings: ${error.message ?? error.code}',
                          );
                        }
                      },
                    ),
                    _menuItem(
                      'storage',
                      _storageRow(),
                      height: 42,
                      onTap: () async {
                        AppLogController.instance.record(
                          'SETTINGS',
                          'Opening Android app information settings for storage permissions',
                        );
                        try {
                          await const MethodChannel('local_wifi_drop/storage')
                              .invokeMethod<void>('openStorageSettings');
                        } on PlatformException catch (error) {
                          AppLogController.instance.record(
                            'ERROR',
                            'Could not open app information settings: ${error.message ?? error.code}',
                          );
                        }
                      },
                    ),
                    _menuItem(
                      'about',
                      Center(child: _menuText('About', bold: true, size: 18)),
                      height: 42,
                      onTap: () {
                        showAboutDialog(
                          context: context,
                          applicationName: 'Local Wifi Drop',
                          applicationVersion: '1.0.113 (Build 6)',
                          applicationLegalese: 'Local Wi-Fi file and message transfer.',
                        );
                      },
                    ),
                    _menuItem('exit', Center(child: _menuText('Exit', bold: true, size: 18)), height: 42),
                  ],
                      ),
                    );
                  },
                ),
              )
            ],
          ),
        ),
        Container(
          height: 48,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: _darkGreen,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Expanded(
                child: _tab(
                  label: 'Send',
                  icon: Icons.send,
                  active: !isReceive,
                  onTap: onSendTap,
                  key: const ValueKey('send-header-send-tab'),
                ),
              ),
              Expanded(
                child: _tab(
                  label: 'Receive',
                  icon: Icons.download,
                  active: isReceive,
                  onTap: onReceiveTap,
                  key: const ValueKey('send-header-receive-tab'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}


class _NoopListenable implements Listenable {
  const _NoopListenable();
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}

class _AlertDropdownButton extends StatelessWidget {
  const _AlertDropdownButton({required this.panel, required this.alertController, super.key});
  final Widget panel;
  final TransferAlertController? alertController;

  @override
  Widget build(BuildContext context) {
    final controller = alertController;
    return AnimatedBuilder(
      animation: controller ?? const _NoopListenable(),
      builder: (context, _) => PopupMenuButton<void>(
      onOpened: () {
        AppLogController.instance.record('UI', 'Alert action list opened');
        controller?.markAlertsViewed();
      },
      tooltip: 'Alerts and transfer history',
      position: PopupMenuPosition.under,
      offset: const Offset(0, 7),
      color: const Color(0xFF202020),
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      constraints: const BoxConstraints(minWidth: 200, maxWidth: 200),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      padding: EdgeInsets.zero,
      itemBuilder: (_) => [
        PopupMenuItem<void>(
          height: 364,
          padding: const EdgeInsets.all(10),
          child: panel,
        ),
      ],
      child: SizedBox(
        key: ValueKey(key == _receiveAlertButtonKey ? 'receive-alerts-button' : 'send-alerts-button'),
        width: 32,
        height: 32,
        child: Material(
          color: controller?.hasUnreadAlert == true ? Colors.red : const Color(0xFF20D65A),
          shape: const CircleBorder(),
          child: Icon(
            Icons.priority_high,
            color: controller?.hasUnreadAlert == true ? Colors.white : Colors.black,
            size: 21,
          ),
        ),
      ),
      ),
    );
  }

  static OverlayEntry? _logOverlayEntry;

  static void closeLogPanel() {
    _logOverlayEntry?.remove();
    _logOverlayEntry = null;
  }

  static void showLogPanel(
    BuildContext context,
    GlobalKey rowKey,
    GlobalKey labelKey,
    GlobalKey? bottomAnchorKey,
  ) {
    final rowBox = rowKey.currentContext?.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context);
    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    if (rowBox == null || overlayBox == null || !rowBox.hasSize) return;

    final labelBox = labelKey.currentContext?.findRenderObject() as RenderBox?;
    if (labelBox == null || !labelBox.hasSize) return;
    final rowGlobal = rowBox.localToGlobal(Offset.zero);
    final rowInOverlay = overlayBox.globalToLocal(rowGlobal);
    final labelGlobal = labelBox.localToGlobal(Offset.zero);
    final labelInOverlay = overlayBox.globalToLocal(labelGlobal);
    // Place the Log panel immediately to the LEFT of the open Options menu.
    // The Log row's left edge is the menu's left edge; keep a small visual gap.
    const gap = 8.0;
    final width = (rowInOverlay.dx - gap)
        .clamp(0.0, 200.0)
        .toDouble();
    final left = (rowInOverlay.dx - gap - width)
        .clamp(0.0, overlayBox.size.width)
        .toDouble();
    final top = labelInOverlay.dy.clamp(0.0, overlayBox.size.height).toDouble();

    final bottomBox = bottomAnchorKey?.currentContext?.findRenderObject() as RenderBox?;
    final bottom = bottomBox != null && bottomBox.hasSize
        ? overlayBox.globalToLocal(bottomBox.localToGlobal(Offset.zero)).dy
        : overlayBox.size.height - MediaQuery.viewInsetsOf(context).bottom - 12;
    const gapAboveSendButton = 8.0;
    final height = (bottom - gapAboveSendButton - top)
        .clamp(0.0, overlayBox.size.height)
        .toDouble();
    if (height <= 0) return;

    _logOverlayEntry?.remove();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (overlayContext) => Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            right: 0,
            height: top + height,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                closeLogPanel();
                Navigator.of(context).pop();
              },
              child: const SizedBox.expand(),
            ),
          ),
          Positioned(
            left: left,
            top: top,
            width: width,
            height: height,
            child: const Material(
              key: ValueKey('log-panel-overlay'),
              color: Colors.transparent,
              child: AppLogPanel(),
            ),
          ),
        ],
      ),
    );
    _logOverlayEntry = entry;
    overlay.insert(entry);
  }

  static Future<void> showPanel(
    BuildContext context,
    GlobalKey buttonKey,
    Widget panel,
  ) async {
    final buttonBox = buttonKey.currentContext?.findRenderObject() as RenderBox?;
    final overlayBox = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (buttonBox == null || overlayBox == null) return;

    final topLeft = buttonBox.localToGlobal(Offset.zero, ancestor: overlayBox);
    // Anchor the menu to the lower edge of the Alert button. A normal
    // button-sized anchor makes showMenu center the tall panel over the icon.
    final menuTop = topLeft.dy + buttonBox.size.height + 7;
    final anchor = RelativeRect.fromLTRB(
      topLeft.dx,
      menuTop,
      overlayBox.size.width - topLeft.dx - buttonBox.size.width,
      overlayBox.size.height - menuTop,
    );
    await showMenu<void>(
      context: context,
      position: anchor,
      color: const Color(0xFF202020),
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      constraints: const BoxConstraints(minWidth: 200, maxWidth: 200),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      items: [
        PopupMenuItem<void>(
          height: 364,
          padding: const EdgeInsets.all(10),
          child: panel,
        ),
      ],
    );
  }
}
