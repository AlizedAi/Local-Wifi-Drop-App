import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_log_controller.dart';

class AppLogPanel extends StatefulWidget {
  const AppLogPanel({super.key});

  @override
  State<AppLogPanel> createState() => _AppLogPanelState();
}

class _AppLogPanelState extends State<AppLogPanel> {
  final ValueNotifier<String?> _selectedText = ValueNotifier(null);

  @override
  void dispose() {
    _selectedText.dispose();
    super.dispose();
  }

  Color _levelColor(AppLogLevel level) => switch (level) {
        AppLogLevel.info => const Color(0xFFB9C7D0),
        AppLogLevel.warning => const Color(0xFFFFC857),
        AppLogLevel.error => const Color(0xFFFF5C5C),
        AppLogLevel.success => const Color(0xFF20D65A),
      };

  String _timestamp(DateTime time) =>
      '${time.year.toString().padLeft(4, '0')}-'
      '${time.month.toString().padLeft(2, '0')}-'
      '${time.day.toString().padLeft(2, '0')} '
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}:'
      '${time.second.toString().padLeft(2, '0')}.'
      '${time.millisecond.toString().padLeft(3, '0')}';

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppLogController.instance,
      builder: (context, _) {
        final entries = AppLogController.instance.entries;
        final logSpans = <InlineSpan>[];
        String? previousTimestamp;

        for (var index = entries.length - 1; index >= 0; index--) {
          final entry = entries[index];
          final timestamp = _timestamp(entry.time);

          if (logSpans.isNotEmpty) {
            logSpans.add(const TextSpan(text: '\n'));
          }

          if (timestamp != previousTimestamp) {
            logSpans.add(TextSpan(
              text: '[$timestamp]\n',
              style: const TextStyle(
                color: Color(0xFF8FA49A),
                fontFamily: 'monospace',
                fontSize: 10,
                height: 1.35,
              ),
            ));
            previousTimestamp = timestamp;
          }

          logSpans.add(TextSpan(
            text: '[${entry.level.name.toUpperCase()}] [${entry.category}] ${entry.message}',
            style: TextStyle(
              color: _levelColor(entry.level),
              fontFamily: 'monospace',
              fontSize: 10,
              height: 1.35,
            ),
          ));
        }

        final logText = TextSpan(children: logSpans).toPlainText();

        return Container(
          width: double.infinity,
          height: double.infinity,
          decoration: BoxDecoration(
            color: const Color(0xF20B0F0D),
            border: Border.all(color: const Color(0xFF20D65A), width: 1),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Column(
            children: [
              Container(
                height: 38,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                decoration: const BoxDecoration(
                  color: Color(0xFF12351F),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.terminal,
                        color: Color(0xFF20D65A), size: 17),
                    const SizedBox(width: 7),
                    const Expanded(
                      child: Text(
                        'SYSTEM LOG',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: .4,
                        ),
                      ),
                    ),
                    Text(
                      '${entries.length} EVENTS',
                      maxLines: 1,
                      style:
                          const TextStyle(color: Colors.white60, fontSize: 8),
                    ),
                    ValueListenableBuilder<String?>(
                      valueListenable: _selectedText,
                      builder: (context, selectedText, _) {
                        final hasValidSelection =
                            selectedText != null && selectedText.isNotEmpty;
                        return IconButton(
                          key: const ValueKey('log-copy-button'),
                          tooltip: 'Copy selected',
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                              width: 28, height: 28),
                          onPressed: !hasValidSelection
                              ? null
                              : () {
                                  Clipboard.setData(
                                      ClipboardData(text: selectedText));
                                },
                          icon: const Icon(Icons.copy,
                              color: Colors.white70, size: 14),
                        );
                      },
                    ),
                    IconButton(
                      tooltip: 'Clear log',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints.tightFor(width: 24, height: 28),
                      onPressed: entries.isEmpty
                          ? null
                          : () {
                              _selectedText.value = null;
                              AppLogController.instance.clear();
                            },
                      icon: const Icon(Icons.delete_outline,
                          color: Colors.white70, size: 14),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: entries.isEmpty
                    ? const Center(
                        child: Text(
                          'Waiting for application events…',
                          style:
                              TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      )
                    : SingleChildScrollView(
                        reverse: true,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 6),
                        child: SelectableText.rich(
                          TextSpan(children: logSpans),
                          onSelectionChanged: (selection, cause) {
                            final start = selection.start;
                            final end = selection.end;
                            _selectedText.value = !selection.isCollapsed &&
                                    start >= 0 &&
                                    end <= logText.length
                                ? logText.substring(start, end)
                                : null;
                          },
                          contextMenuBuilder: (context, editableTextState) {
                            final allowedItems = editableTextState
                                .contextMenuButtonItems
                                .where((item) =>
                                    item.type ==
                                    ContextMenuButtonType.selectAll)
                                .toList();
                            return AdaptiveTextSelectionToolbar.buttonItems(
                              anchors:
                                  editableTextState.contextMenuAnchors,
                              buttonItems: allowedItems,
                            );
                          },
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
