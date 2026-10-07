import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../models/models.dart';
import '../../state/jira_controller.dart';
import '../../state/tracker_controller.dart';
import '../../state/trello_controller.dart';
import '../../state/workspace_session.dart';
import '../../widgets/common.dart';
import '../jira/jira_status_menu.dart';
import '../tasks/task_picker.dart';
import '../tracker/tracker_logic.dart';

/// What the editor did; null when it was closed without changes.
enum EntryEditResult { saved, deleted }

/// Edits or deletes a time entry: one in Time-Wise, or one kept on this Mac
/// ([local]).
///
/// Dialogs sit above the workspace providers, so they're handed over here.
Future<EntryEditResult?> showEntryEditor(
  BuildContext context, {
  required TimeEntry entry,
  PendingEntry? local,
}) {
  final session = context.read<WorkspaceSession>();
  final tracker = context.read<TrackerController>();
  final jira = context.read<JiraController>();
  final trello = context.read<TrelloController>();
  return showDialog<EntryEditResult>(
    context: context,
    builder: (_) => _EntryEditor(
      entry: entry,
      local: local,
      session: session,
      tracker: tracker,
      jira: jira,
      trello: trello,
    ),
  );
}

class _EntryEditor extends StatefulWidget {
  const _EntryEditor({
    required this.entry,
    required this.local,
    required this.session,
    required this.tracker,
    required this.jira,
    required this.trello,
  });

  final TimeEntry entry;
  final PendingEntry? local;
  final WorkspaceSession session;
  final TrackerController tracker;
  final JiraController jira;
  final TrelloController trello;

  @override
  State<_EntryEditor> createState() => _EntryEditorState();
}

class _EntryEditorState extends State<_EntryEditor> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _description;
  late final TextEditingController _hours;
  late final TextEditingController _minutes;
  late int _projectId;
  late DateTime _date;
  late Set<int> _tagIds;
  late bool _billable;
  bool _saving = false;
  String? _error;

  bool get _isLocal => widget.local != null;

  /// A local entry under a minute may stay at 0h 0m (it keeps its seconds).
  bool get _mayBeZero => widget.local?.underAMinute ?? false;

  @override
  void initState() {
    super.initState();
    final e = widget.entry;
    _title = TextEditingController(text: e.taskTitle);
    _description = TextEditingController(text: e.description ?? '');
    _hours = TextEditingController(text: '${e.totalMinutes ~/ 60}');
    _minutes = TextEditingController(text: '${e.totalMinutes % 60}');
    _projectId = e.projectId;
    _date = parseDateKey(e.date);
    _tagIds = widget.local?.tagIds.toSet() ?? {for (final t in e.tags) t.id};
    _billable = e.billable;
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _hours.dispose();
    _minutes.dispose();
    super.dispose();
  }

  /// Assigned active projects, plus the entry's own if it's since been archived.
  List<Project> get _projects {
    final list = [...widget.session.trackableProjects];
    final current = widget.entry.project;
    if (current != null && !list.any((p) => p.id == current.id)) list.insert(0, current);
    return list;
  }

  int get _totalMinutes =>
      (int.tryParse(_hours.text.trim()) ?? 0) * 60 + (int.tryParse(_minutes.text.trim()) ?? 0);

  Future<void> _pickDate() async {
    final today = dateOnly(DateTime.now());
    final yearAgo = today.subtract(const Duration(days: 365));
    final picked = await showDatePicker(
      context: context,
      initialDate: _date.isAfter(today) ? today : _date,
      firstDate: _date.isBefore(yearAgo) ? _date : yearAgo,
      lastDate: today,
    );
    if (picked != null) setState(() => _date = dateOnly(picked));
  }

  Future<void> _pickTask(RelativeRect position) async {
    final task = await pickTask(context, jira: widget.jira, trello: widget.trello, position: position);
    if (task == null || !mounted) return;
    setState(() {
      _title.text = task.title.length > 500 ? task.title.substring(0, 500) : task.title;
      final description = task.description;
      if (description != null && _description.text.trim().isEmpty) {
        _description.text = description.length > 1000 ? description.substring(0, 1000) : description;
      }
    });
  }

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    final total = _totalMinutes;
    final project = _projects.firstWhere((p) => p.id == _projectId);
    final description = _description.text.trim();
    final payload = <String, dynamic>{
      'projectId': _projectId,
      'taskTitle': _title.text.trim(),
      'description': description.isEmpty ? null : description,
      'hours': total ~/ 60,
      'minutes': total % 60,
      'date': dateKey(_date),
      'billable': _billable,
      'tagIds': _tagIds.toList()..sort(),
    };

    final local = widget.local;
    if (local != null) {
      widget.tracker.updateLocal(local.id, payload, projectName: project.name);
      Navigator.pop(context, EntryEditResult.saved);
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.session.updateEntry(widget.entry.id, payload);
      if (mounted) Navigator.pop(context, EntryEditResult.saved);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    if (_saving) return;
    final entry = widget.entry;
    final local = widget.local;
    final duration = local != null && local.underAMinute
        ? '${local.seconds ?? 0}s'
        : formatMinutes(entry.totalMinutes);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(local != null ? 'Delete from this Mac?' : 'Delete from Time-Wise?'),
        content: Text('$duration on "${entry.taskTitle}" will be deleted. This can\'t be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    if (local != null) {
      widget.tracker.deleteLocal(local.id);
      Navigator.pop(context, EntryEditResult.deleted);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.session.deleteEntry(entry.id);
      if (mounted) Navigator.pop(context, EntryEditResult.deleted);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _validateDuration() {
    final total = _totalMinutes;
    if (total > maxEntryMinutes) return 'An entry can be at most 24 hours.';
    if (total == 0 && !_mayBeZero) return 'Enter at least 1 minute.';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final projects = _projects;
    const gap = SizedBox(height: 10);

    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 680),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 4, 4),
              child: Row(
                children: [
                  Text('Edit entry', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(width: 8),
                  _WhereBadge(local: _isLocal),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Close',
                    iconSize: 18,
                    icon: const Icon(Icons.close),
                    onPressed: _saving ? null : () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: scheme.outlineVariant),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      DropdownButtonFormField<int>(
                        initialValue: projects.any((p) => p.id == _projectId) ? _projectId : null,
                        isExpanded: true,
                        isDense: true,
                        decoration: _decoration('Project', Icons.folder_outlined),
                        items: [
                          for (final p in projects)
                            DropdownMenuItem(
                              value: p.id,
                              child: Row(
                                children: [
                                  ColorDot(p.color, size: 8),
                                  const SizedBox(width: 8),
                                  Flexible(child: Text(p.name, overflow: TextOverflow.ellipsis)),
                                ],
                              ),
                            ),
                        ],
                        validator: (v) => v == null ? 'Select a project' : null,
                        onChanged: _saving ? null : (id) => setState(() => _projectId = id ?? _projectId),
                      ),
                      gap,
                      TextFormField(
                        controller: _title,
                        enabled: !_saving,
                        maxLength: 500,
                        decoration: _decoration('Task title', Icons.task_alt_outlined).copyWith(
                          counterText: '',
                          suffixIcon: hasTaskSource(widget.jira, widget.trello)
                              ? Builder(
                                  builder: (anchor) => IconButton(
                                    tooltip: pickTaskTooltip(widget.jira, widget.trello),
                                    iconSize: 18,
                                    icon: const Icon(Icons.manage_search),
                                    onPressed: _saving ? null : () => _pickTask(menuPositionBelow(anchor)),
                                  ),
                                )
                              : null,
                          suffixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 34),
                        ),
                        validator: (v) => (v ?? '').trim().isEmpty ? 'Enter a task title' : null,
                      ),
                      gap,
                      TextFormField(
                        controller: _description,
                        enabled: !_saving,
                        maxLength: 1000,
                        minLines: 1,
                        maxLines: 3,
                        decoration: _decoration('Description (optional)', Icons.notes).copyWith(counterText: ''),
                      ),
                      gap,
                      InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: _saving ? null : _pickDate,
                        child: InputDecorator(
                          decoration: _decoration('Date', Icons.calendar_today_outlined),
                          child: Text(formatDay(_date)),
                        ),
                      ),
                      gap,
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _hours,
                              enabled: !_saving,
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                                LengthLimitingTextInputFormatter(2),
                              ],
                              decoration: _decoration('Hours', Icons.schedule),
                              onChanged: (_) => setState(() {}),
                              validator: (_) => _validateDuration(),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextFormField(
                              controller: _minutes,
                              enabled: !_saving,
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                                LengthLimitingTextInputFormatter(2),
                              ],
                              decoration: const InputDecoration(labelText: 'Minutes'),
                              onChanged: (_) => setState(() {}),
                              validator: (v) =>
                                  (int.tryParse(v ?? '') ?? 0) > 59 ? 'Up to 59' : null,
                            ),
                          ),
                        ],
                      ),
                      if (_mayBeZero && _totalMinutes == 0) ...[
                        const SizedBox(height: 4),
                        Text(
                          'Tracked ${widget.local!.seconds ?? 0}s. It uploads as 1 minute, Time-Wise\'s minimum.',
                          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Text(
                        'Tags',
                        style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 4),
                      _tags(theme),
                      const SizedBox(height: 4),
                      SwitchListTile(
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Billable'),
                        value: _billable,
                        onChanged: _saving ? null : (v) => setState(() => _billable = v),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: InlineNotice(message: _error!, icon: Icons.error_outline, isError: true),
              ),
            Divider(height: 1, color: scheme.outlineVariant),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: _saving ? null : _delete,
                    style: TextButton.styleFrom(foregroundColor: scheme.error),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Delete'),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.5))
                        : const Text('Save'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tags(ThemeData theme) {
    final tags = widget.session.tags.data ?? const <Tag>[];
    if (tags.isEmpty) {
      return Text(
        'This workspace has no tags yet.',
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      );
    }
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final tag in tags)
          FilterChip(
            visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: const EdgeInsets.symmetric(horizontal: 2),
            labelPadding: const EdgeInsets.only(left: 2, right: 4),
            labelStyle: theme.textTheme.labelSmall,
            avatar: ColorDot(tag.color, size: 6),
            label: Text(tag.name),
            selected: _tagIds.contains(tag.id),
            showCheckmark: false,
            onSelected: _saving
                ? null
                : (_) => setState(() {
                      _tagIds = _tagIds.contains(tag.id)
                          ? ({..._tagIds}..remove(tag.id))
                          : {..._tagIds, tag.id};
                    }),
          ),
      ],
    );
  }
}

/// Where the entry lives: on this Mac only, or in Time-Wise.
class _WhereBadge extends StatelessWidget {
  const _WhereBadge({required this.local});

  final bool local;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = local ? scheme.tertiary : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: local ? scheme.tertiaryContainer.withValues(alpha: 0.4) : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(local ? Icons.laptop_mac_outlined : Icons.cloud_done_outlined, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            local ? 'On this Mac' : 'In Time-Wise',
            style: theme.textTheme.labelSmall?.copyWith(color: color, fontSize: 10),
          ),
        ],
      ),
    );
  }
}

InputDecoration _decoration(String label, IconData icon) => InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon, size: 18),
      prefixIconConstraints: const BoxConstraints(minWidth: 38, minHeight: 36),
    );
