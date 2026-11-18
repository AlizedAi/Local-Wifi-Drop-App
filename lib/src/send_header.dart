import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_log_panel.dart';
import 'app_log_controller.dart';
import 'app_language_controller.dart';
import 'transfer_alert_controller.dart';

/// Shared visual header for the Send and Receive pages.
final GlobalKey _logMenuItemKey = GlobalKey();
final GlobalKey _logMenuLabelKey = GlobalKey();

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
    required this.alertButtonKey,
    this.logPanelBottomKey,
    super.key,
  });

  final VoidCallback onReceiveTap;
  final VoidCallback onSendTap;
  final bool isReceive;
  final Widget? alertsPanel;
  final TransferAlertController? alertController;
  final GlobalKey alertButtonKey;
  final GlobalKey? logPanelBottomKey;

  static const Color _darkGreen = Color(0xFF073B20);
  static const Color _brightGreen = Color(0xFF20D65A);
  static const Color _menuBackground = Colors.black;

  String _tr(String value) => AppLanguageController.instance.translate(value);

  Widget _tab({
    required String label,
    required IconData icon,
    required bool active,
    required VoidCallback onTap,
    required Key key,
  }) {
    return Material(
      color: active ? const Color(0xFF20C65A) : Colors.transparent,
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
                    _tr(label),
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

  Widget _menuText(String value, {Key? key}) {
    return Text(
      _tr(value),
      key: key,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 17,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  Widget _wifiRow() => Center(
        child: _menuText('Wifi', key: const ValueKey('options-wifi-label')),
      );

  Widget _notificationRow() => Center(
        child: _menuText('Notifications', key: const ValueKey('options-notifications-label')),
      );

  Widget _storageRow() => Center(
        child: _menuText('Storage', key: const ValueKey('options-storage-label')),
      );

  void _showImportantDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.black,
        icon: const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 34),
        title: Text(
          _tr('Important'),
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.w800),
        ),
        content: Text(
          _tr('Files and messages are transferred over your local Wi-Fi network without encryption. Do not send passwords, financial information, private documents, or other sensitive content. Only transfer files to devices and people you trust.'),
          style: const TextStyle(color: Colors.white),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(_tr('I understand')),
          ),
        ],
      ),
    );
  }

  void _showAboutDialog(BuildContext context) {
    final aboutText = AppLanguageController.instance.isPersian
        ? 'سازنده : Ali.z با کمک Chat GPT به اسم Nova\n\n'
            'تماس با ما : Zeydi.Ali.71@Gmail.com\n\n'
            'توضیحات :\n'
            'شما میتوانید به کمک این نرم افزار با اتصال به یک wifi مشترک فایل با حجم بالا و سریع ارسال و دریافت کنید\n\n'
            'امکانات :\n'
            'بدون مصرف اینترنت\n'
            'ارسال فایل های حجیم با سرعت بالا\n'
            'ارسال و دریافت پیام در خود نرم افزار\n\n'
            'نکات مهم :\n'
            'از دریافت فایل از IP های نامشخص خودداری کنید\n'
            'این برنامه برای اتصال راحتتر و سبک رمزگزاری ندارد\n'
            'از ارسال فایلهای حساس هنگام اتصال به مودم های عمومی جدا خودداری کنید.\n'
            'برای دریافت فایل حتما باید در صفحه ی دریافت باشید.\n\n'
            'امیدوارم لذت ببرید'
        : 'Creator: Ali.z with the help of ChatGPT named Nova\n\n'
            'Contact us: Zeydi.Ali.71@gmail.com\n\n'
            'Description:\n'
            'With this app, you can quickly send and receive large files by connecting to the same Wi-Fi network.\n\n'
            'Features:\n'
            'No internet usage\n'
            'High-speed transfer of large files\n'
            'Send and receive messages within the app\n\n'
            'Important notes:\n'
            'Do not accept files from unknown IP addresses.\n'
            'This app does not use encryption to make connections easier and keep it lightweight.\n'
            'Never send sensitive files while connected to public Wi-Fi routers.\n'
            'To receive files, you must be on the Receive tab.\n\n'
            'I hope you enjoy it.';
    final windowsVersion = const String.fromEnvironment(
      'APP_VERSION',
      defaultValue: '1.0.159',
    );
    final versionSuffix = Platform.isWindows
        ? (AppLanguageController.instance.isPersian
            ? '\n\nنسخه: $windowsVersion'
            : '\n\nVersion: $windowsVersion')
        : '';
    final displayAboutText = '$aboutText$versionSuffix';

    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.black,
        title: const Text(
          'Local Wi-Fi Drop',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white),
        ),
        content: SingleChildScrollView(
          child: SelectableText(
            displayAboutText,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, height: 1.45),
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(_tr('Close')),
          ),
        ],
      ),
    );
  }

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
              Navigator.of(context, rootNavigator: true).pop();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
              child: Text(
                code,
                style: TextStyle(
                  color: active ? const Color(0xFF20D65A) : Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          );
        }

        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Center(child: _menuText('Languages')),
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
                    key: alertButtonKey,
                    isReceive: isReceive,
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
                  tooltip: _tr('Options'),
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
                      if (Platform.isWindows) {
                        exit(0);
                      } else {
                        SystemNavigator.pop();
                      }
                    }
                    // Settings destinations are handled by each item's onTap callback.
                  },
                  itemBuilder: (context) => [
                    _menuItem(
                      'important',
                      Center(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 19),
                            const SizedBox(width: 7),
                            Flexible(
                              child: Text(
                                _tr('IMPORTANT'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.orange,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      height: 46,
                      onTap: () => _showImportantDialog(context),
                    ),
                    _menuItem('languages', _languageRow(), height: 64),
                    if (!Platform.isWindows) ...[
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
                    ],
                    PopupMenuItem<String>(
                      value: 'alert',
                      height: 40,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      onTap: () {
                        if (alertsPanel != null) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            _AlertDropdownButton.showPanel(
                              context,
                              alertButtonKey,
                              alertsPanel!,
                            );
                          });
                        }
                      },
                      child: Center(child: _menuText('Alert')),
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
                        child: _menuText('Log', key: _logMenuLabelKey),
                      ),
                    ),
                    _menuItem(
                      'about',
                      Center(child: _menuText('About')),
                      height: 42,
                      onTap: () => _showAboutDialog(context),
                    ),
                    _menuItem('exit', Center(child: _menuText('Exit')), height: 42),
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
  const _AlertDropdownButton({required this.panel, required this.alertController, required this.isReceive, super.key});
  final Widget panel;
  final TransferAlertController? alertController;
  final bool isReceive;

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
      tooltip: AppLanguageController.instance.translate('Alerts and transfer history'),
      position: PopupMenuPosition.under,
      offset: const Offset(0, 7),
      color: Colors.black,
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
        key: ValueKey(isReceive ? 'receive-alerts-button' : 'send-alerts-button'),
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
      color: Colors.black,
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
