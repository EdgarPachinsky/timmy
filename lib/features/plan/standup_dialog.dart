import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/claude_cli.dart';
import '../../core/planner.dart';
import '../../state/claude_controller.dart';
import 'step_progress.dart';

/// A standup from yesterday's entries, today's so far and the plan. Starts
/// from a plain template of what's loaded; [prepare] then fetches fresh data
/// step by step (shown under the title), and with Claude connected, Claude
/// writes it. Editable, with Copy.
Future<void> showStandupDialog(
  BuildContext context, {
  required ClaudeController claude,
  required StandupData data,
  required DateTime now,
  ValueChanged<String>? onWritten,
  Future<StandupData?> Function(StepRunner step)? prepare,
}) =>
    showDialog<void>(
      context: context,
      builder: (_) => _StandupDialog(
        claude: claude,
        data: data,
        now: now,
        onWritten: onWritten,
        prepare: prepare,
      ),
    );

class _StandupDialog extends StatefulWidget {
  const _StandupDialog({
    required this.claude,
    required this.data,
    required this.now,
    this.onWritten,
    this.prepare,
  });

  final ClaudeController claude;
  final StandupData data;
  final DateTime now;

  /// A finished standup: Claude wrote it, or it was copied (as edited).
  final ValueChanged<String>? onWritten;

  /// Fetches fresh material, reporting each step.
  final Future<StandupData?> Function(StepRunner step)? prepare;

  @override
  State<_StandupDialog> createState() => _StandupDialogState();
}

class _StandupDialogState extends State<_StandupDialog> {
  late final TextEditingController _text = TextEditingController(text: standupTemplate(widget.data, widget.now));
  late StandupData _data = widget.data;
  bool _writing = false;
  bool _byClaude = false;
  String? _error;

  /// The step being shown under the title while working.
  ProgressStep? _progress;
  late final StepRunner _step = stepRunner(
    mounted: () => mounted,
    show: (s) => setState(() => _progress = s),
  );

  @override
  void initState() {
    super.initState();
    _run(gather: true);
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  /// With [gather], fresh data first (Jira, Trello, entries); then, with
  /// Claude connected, Claude writes it. Every step shows under the title.
  Future<void> _run({required bool gather}) async {
    final prepare = widget.prepare;
    if (!(gather && prepare != null) && !widget.claude.isConnected) return;
    setState(() {
      _writing = true;
      _error = null;
    });
    try {
      if (gather && prepare != null) {
        final data = await prepare(_step);
        if (!mounted) return;
        if (data != null) {
          setState(() {
            _data = data;
            _text.text = standupTemplate(data, widget.now);
          });
        }
      }
      if (widget.claude.isConnected) {
        await _step('Claude is writing your standup', () async {
          final answer = await widget.claude.ask(
            kind: 'standup',
            instruction: standupInstruction,
            input: const JsonEncoder.withIndent('  ').convert(standupInput(_data, widget.now)),
          );
          if (!mounted || answer.text.isEmpty) return false;
          setState(() {
            _text.text = answer.text;
            _byClaude = true;
          });
          widget.onWritten?.call(answer.text);
          return true;
        });
      }
    } on ClaudeException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) {
        setState(() {
          _writing = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _copy() async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: _text.text));
    widget.onWritten?.call(_text.text);
    if (!mounted) return;
    Navigator.pop(context);
    messenger.showSnackBar(const SnackBar(content: Text('Standup copied.')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
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
                  if (!_writing && _byClaude)
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
            // Gathering data and Claude writing, one step at a time.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: StepProgress(step: _progress),
            ),
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
                      onPressed: _writing ? null : () => _run(gather: false),
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
