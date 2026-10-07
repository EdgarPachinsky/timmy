import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/claude_cli.dart';
import '../../core/planner.dart';
import '../../state/claude_controller.dart';

/// A standup from yesterday's entries, today's so far and the plan. Starts
/// from a plain template; with Claude connected, Claude writes it. Editable,
/// with Copy.
Future<void> showStandupDialog(
  BuildContext context, {
  required ClaudeController claude,
  required StandupData data,
  required DateTime now,
}) =>
    showDialog<void>(
      context: context,
      builder: (_) => _StandupDialog(claude: claude, data: data, now: now),
    );

class _StandupDialog extends StatefulWidget {
  const _StandupDialog({required this.claude, required this.data, required this.now});

  final ClaudeController claude;
  final StandupData data;
  final DateTime now;

  @override
  State<_StandupDialog> createState() => _StandupDialogState();
}

class _StandupDialogState extends State<_StandupDialog> {
  late final TextEditingController _text = TextEditingController(text: standupTemplate(widget.data, widget.now));
  bool _writing = false;
  bool _byClaude = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.claude.isConnected) _askClaude();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _askClaude() async {
    setState(() {
      _writing = true;
      _error = null;
    });
    try {
      final answer = await widget.claude.ask(
        kind: 'standup',
        instruction: standupInstruction,
        input: const JsonEncoder.withIndent('  ').convert(standupInput(widget.data, widget.now)),
      );
      if (!mounted) return;
      if (answer.text.isNotEmpty) {
        setState(() {
          _text.text = answer.text;
          _byClaude = true;
        });
      }
    } on ClaudeException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  Future<void> _copy() async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: _text.text));
    if (!mounted) return;
    Navigator.pop(context);
    messenger.showSnackBar(const SnackBar(content: Text('Standup copied.')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 620),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 4, 0),
              child: Row(
                children: [
                  Text('Standup', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(width: 8),
                  if (_writing)
                    Text('Claude is writing…', style: theme.textTheme.labelSmall?.copyWith(color: muted))
                  else if (_byClaude)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.auto_awesome, size: 12, color: scheme.primary),
                        const SizedBox(width: 3),
                        Text('By Claude', style: theme.textTheme.labelSmall?.copyWith(color: scheme.primary)),
                      ],
                    ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Close',
                    iconSize: 18,
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            SizedBox(height: 2, child: _writing ? const LinearProgressIndicator(minHeight: 2) : null),
            Flexible(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: SizedBox(
                  height: 340,
                  // Fills the box and scrolls inside it when the text is long.
                  child: TextField(
                    controller: _text,
                    readOnly: _writing,
                    expands: true,
                    maxLines: null,
                    textAlignVertical: TextAlignVertical.top,
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
                    decoration: const InputDecoration(contentPadding: EdgeInsets.all(12)),
                  ),
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
                child: Text(
                  "Claude couldn't write it ($_error). Here's the plain version.",
                  style: theme.textTheme.labelSmall?.copyWith(color: scheme.error),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              child: Row(
                children: [
                  if (widget.claude.isConnected)
                    TextButton.icon(
                      onPressed: _writing ? null : _askClaude,
                      icon: const Icon(Icons.auto_awesome, size: 16),
                      label: Text(_byClaude ? 'Rewrite' : 'Write with Claude'),
                    ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: _writing ? null : _copy,
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('Copy'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
