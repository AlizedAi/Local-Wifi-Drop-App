import 'package:flutter/material.dart';

import 'transfer_alert_controller.dart';

/// Compact, live-updating send/receive action list for the header dropdown.
class TransferHistoryPanel extends StatelessWidget {
  const TransferHistoryPanel({required this.controller, super.key});

  final TransferAlertController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return SizedBox(
          key: const ValueKey('action-list-panel'),
          width: 180,
          height: 344,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text('Alert List', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800, letterSpacing: .5)),
                  ),
                  IconButton(
                    tooltip: 'Clear history',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(width: 28, height: 28),
                    onPressed: controller.items.isEmpty ? null : controller.clear,
                    icon: const Icon(Icons.delete_outline, color: Colors.white70, size: 18),
                  ),
                ],
              ),
              const Divider(color: Colors.white24, height: 12),
            ],
          ),
        );
      },
    );
  }

}
