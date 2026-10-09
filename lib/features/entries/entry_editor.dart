import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/claude_cli.dart';
import '../../core/entry_description.dart';
import '../../core/format.dart';
import '../../core/planner.dart' show jiraKeysIn;
import '../../models/jira.dart';
import '../../models/models.dart';
import '../../models/trello.dart';
import '../../state/claude_controller.dart';
import '../../state/jira_controller.dart';
import '../../state/tracker_controller.dart';
import '../../state/trello_controller.dart';
import '../../state/workspace_session.dart';
import '../../widgets/common.dart';
import '../jira/jira_status_menu.dart';
import '../tasks/task_picker.dart';
import '../tracker/tracker_logic.dart';

/// Starting values for "Add time" (e.g. a task from the plan, with its
/// planned time). Anything left null gets the usual default.
class EntryDraft {
  const EntryDraft({this.projectId, this.title, this.description, this.minutes, this.date});

  final int? projectId;
  final String? title;
  final String? description;
  final int? minutes;
  final DateTime? date;
}

/// What the editor did; null when it was closed without changes.
enum EntryEditResult { saved, deleted, addedToTimeWise, addedOnThisMac }

/// Edits or deletes a time entry: one in Time-Wise, or one kept on this Mac
/// ([local]). Without an [entry] it adds time by hand, to Time-Wise or this
/// Mac, without the timer.
///
/// Dialogs sit above the workspace providers, so they're handed over here.
Future<EntryEditResult?> showEntryEditor(
  BuildContext context, {
  TimeEntry? entry,
  PendingEntry? local,
  EntryDraft? draft,
}) {
  final session = context.read<WorkspaceSession>();
  final tracker = context.read<TrackerController>();
  final jira = context.read<JiraController>();
  final trello = context.read<TrelloController>();
  final claude = context.read<ClaudeController>();
  return showDialog<EntryEditResult>(
    context: context,
    builder: (_) => _EntryEditor(
      entry: entry,
      local: local,
      draft: draft,
      session: session,
      tracker: tracker,
      jira: jira,
      trello: trello,
      claude: claude,
    ),
  );
}

/// "Add time": the editor without an entry (starting from [draft], if any),
/// then a note on where it went.
Future<void> addTimeManually(BuildContext context, {EntryDraft? draft}) async {
  final messenger = ScaffoldMessenger.of(context);
  final result = await showEntryEditor(context, draft: draft);
  if (result == null) return;
  messenger.showSnackBar(SnackBar(
    content: Text(result == EntryEditResult.addedOnThisMac
        ? 'Time added on this Mac. Upload it from Entries when ready.'
        : 'Time added to Time-Wise.'),
  ));
}

class _EntryEditor extends StatefulWidget {
  const _EntryEditor({
    required this.entry,
    required this.local,
    this.draft,
    required this.session,
    required this.tracker,
    required this.jira,
    required this.trello,
    required this.claude,
  });

  /// Null when adding time by hand.
  final TimeEntry? entry;

  /// Starting values when adding time.
  final EntryDraft? draft;
  final PendingEntry? local;
  final WorkspaceSession session;
  final TrackerController tracker;
  final JiraController jira;
  final TrelloController trello;

  /// Writes a short description when asked (if connected).
  final ClaudeController claude;

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

  /// Adding time by hand rather than editing an entry.
  bool get _isNew => widget.entry == null;

  /// Where new time goes: Time-Wise, or kept on this Mac.
  bool _addToTimeWise = true;

  /// A local entry under a minute may stay at 0h 0m (it keeps its seconds).
  bool get _mayBeZero => widget.local?.underAMinute ?? false;

  @override
  void initState() {
    super.initState();
    final e = widget.entry;
    if (e == null) {
      // New time: today, on the project and billable setting last tracked,
      // unless the draft says otherwise.
      final tracker = widget.tracker;
      final projects = widget.session.trackableProjects;
      final draft = widget.draft;
      final minutes = draft?.minutes;
      _title = TextEditingController(text: draft?.title ?? '');
      _description = TextEditingController(text: draft?.description ?? '');
      _hours = TextEditingController(text: minutes == null ? '' : '${minutes ~/ 60}');
      _minutes = TextEditingController(text: minutes == null ? '' : '${minutes % 60}');
      _projectId = projects.any((p) => p.id == draft?.projectId)
          ? draft!.projectId!
          : projects.any((p) => p.id == tracker.projectId)
              ? tracker.projectId!
              : (projects.firstOrNull?.id ?? -1);
      _date = dateOnly(draft?.date ?? DateTime.now());
      _tagIds = {};
      _billable = tracker.billable;
      return;
    }
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
    final current = widget.entry?.project;
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

  /// Claude is writing the description.
  bool _describing = false;

  /// Asks Claude for a very short "what was done" from the task: its Jira
  /// issue or Trello card description (when found), earlier notes on it, the
  /// project and the time.
  Future<void> _generateDescription() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _error = 'Add a task title first, so Claude knows what the work was.');
      return;
    }
    setState(() {
      _describing = true;
      _error = null;
    });
    try {
      // The Jira issue the title names, and the Trello card it matches.
      JiraIssue? issue;
      final key = jiraKeysIn(title).firstOrNull;
      if (key != null && widget.jira.isConnected) {
        try {
          issue = (await widget.jira.issuesByKeys([key])).firstOrNull;
        } catch (_) {
          // Without the issue, the title and notes still help.
        }
      }
      TrelloCard? card;
      if (issue == null && widget.trello.isConnected) {
        try {
          final norm = title.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
          card = (await widget.trello.findCards('')).where((c) {
            final name = c.name.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
            return name.length >= 4 && (norm == name || norm.contains(name));
          }).firstOrNull;
        } catch (_) {
          // No card then; the title and notes still help.
        }
      }
      final project = _projects.where((p) => p.id == _projectId).firstOrNull;
      final answer = await widget.claude.ask(
        kind: 'entry description',
        instruction: entryDescriptionInstruction,
        input: _prettyJson(entryDescriptionInput(
          title: title,
          project: project?.name,
          minutes: _totalMinutes,
          date: _date,
          issue: issue,
          card: card,
          earlierNotes: earlierNotesFor(widget.session.entries.data ?? const [], title),
        )),
      );
      final text = cleanEntryDescription(answer.text);
      if (!mounted) return;
      if (text.isEmpty) {
        setState(() => _error = 'Claude didn\'t suggest anything. Try again or type it.');
      } else if (_description.text.trim().isEmpty) {
        // Only if nothing was typed meanwhile.
        setState(() => _description.text = text);
      }
    } on ClaudeException catch (e) {
      if (mounted) setState(() => _error = "Claude couldn't write it: ${e.message}");
    } finally {
      if (mounted) setState(() => _describing = false);
    }
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
    if (_isNew && !_addToTimeWise) {
      widget.tracker.addLocal(payload, projectName: project.name);
      Navigator.pop(context, EntryEditResult.addedOnThisMac);
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final entry = widget.entry;
      if (entry == null) {
        await widget.session.createEntry(payload);
      } else {
        await widget.session.updateEntry(entry.id, payload);
      }
      if (mounted) {
        Navigator.pop(context, entry == null ? EntryEditResult.addedToTimeWise : EntryEditResult.saved);
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final entry = widget.entry;
    if (_saving || entry == null) return;
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
                  Text(
                    _isNew ? 'Add time' : 'Edit entry',
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(width: 8),
                  if (!_isNew) _WhereBadge(local: _isLocal),
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
                      if (_isNew) ...[
                        SegmentedButton<bool>(
                          showSelectedIcon: false,
                          style: const ButtonStyle(visualDensity: VisualDensity.compact),
                          segments: const [
                            ButtonSegment(
                              value: true,
                              icon: Icon(Icons.cloud_upload_outlined, size: 16),
                              label: Text('Time-Wise'),
                            ),
                            ButtonSegment(
                              value: false,
                              icon: Icon(Icons.laptop_mac_outlined, size: 16),
                              label: Text('This Mac'),
                            ),
                          ],
                          selected: {_addToTimeWise},
                          onSelectionChanged:
                              _saving ? null : (v) => setState(() => _addToTimeWise = v.first),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _addToTimeWise ? 'Saved to Time-Wise now.' : 'Kept on this Mac; upload it later from Entries.',
                          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 12),
                      ],
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
                        readOnly: _describing,
                        maxLength: 1000,
                        minLines: 1,
                        maxLines: 3,
                        // Shows or hides the Claude button as text comes and goes.
                        onChanged: (_) => setState(() {}),
                        decoration: _decoration('Description (optional)', Icons.notes).copyWith(
                          counterText: '',
                          suffixIcon: !widget.claude.isConnected || (_description.text.trim().isNotEmpty && !_describing)
                              ? null
                              : _describing
                                  ? const Padding(
                                      padding: EdgeInsets.all(10),
                                      child: SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      ),
                                    )
                                  : IconButton(
                                      tooltip: 'Write what was done with Claude, from the task',
                                      iconSize: 18,
                                      color: scheme.primary,
                                      icon: const Icon(Icons.auto_awesome),
                                      onPressed: _saving ? null : _generateDescription,
                                    ),
                          suffixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 34),
                        ),
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
                  if (!_isNew)
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
                        : Text(_isNew ? 'Add' : 'Save'),
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

/// Indented so the input stays readable if someone inspects it.
final _prettyJson = const JsonEncoder.withIndent('  ').convert;
