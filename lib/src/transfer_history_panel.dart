import 'package:flutter/material.dart';

import 'transfer_alert_controller.dart';
import 'transfer_alert.dart';
import 'app_language_controller.dart';

/// Compact, live-updating send/receive action list for the header dropdown.
class TransferHistoryPanel extends StatelessWidget {
  const TransferHistoryPanel({required this.controller, super.key});

  final TransferAlertController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([controller, AppLanguageController.instance.language]),
      builder: (context, _) {
        return ColoredBox(
          color: Colors.black,
          child: SizedBox(
            key: const ValueKey('action-list-panel'),
            width: 180,
            height: 344,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
              Row(
                children: [
                  Expanded(
                    child: Text(AppLanguageController.instance.translate('Alert List'), style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800, letterSpacing: .5)),
                  ),
                  IconButton(
                    tooltip: AppLanguageController.instance.translate('Clear history'),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(width: 28, height: 28),
                    onPressed: controller.items.isEmpty ? null : controller.clear,
                    icon: const Icon(Icons.delete_outline, color: Colors.white70, size: 18),
                  ),
                ],
              ),
              const Divider(color: Colors.white24, height: 12),
              Expanded(
                child: controller.items.isEmpty
                    ? Center(
                        child: Text(
                          AppLanguageController.instance.translate('No file activity yet'),
                          style: const TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      )
                    : ListView.builder(
                        key: const ValueKey('transfer-alert-items'),
                        padding: EdgeInsets.zero,
                        itemCount: controller.items.length > 8 ? 8 : controller.items.length,
                        itemBuilder: (context, index) {
                          final item = controller.items[index];
                          final isSend = item.direction == TransferDirection.send;
                          final statusColor = item.status == TransferAlertStatus.sent ||
                                  item.status == TransferAlertStatus.received
                              ? const Color(0xFF20D65A)
                              : item.status == TransferAlertStatus.failed
                                  ? const Color(0xFFFF5B5B)
                                  : const Color(0xFFFFC857);
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 7),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  isSend ? Icons.upload : Icons.download,
                                  color: statusColor,
                                  size: 15,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        item.fileName,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 11,
                                        ),
                                      ),
                                      Text(
                                        '${AppLanguageController.instance.translate(isSend ? 'Send' : 'Receive')} · ${AppLanguageController.instance.translate(item.status.name.toUpperCase())}',
                                        style: TextStyle(
                                          color: statusColor,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
          ),
        );
      },
    );
  }

}
