import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/overtime.dart';
import '../../models/models.dart';
import '../../state/tracker_controller.dart';
import '../../state/workspace_session.dart';
import '../../widgets/common.dart';
import 'entry_editor.dart';

class EntriesPage extends StatefulWidget {
  const EntriesPage({super.key});

  @override
  State<EntriesPage> createState() => _EntriesPageState();
}

class _EntriesPageState extends State<EntriesPage> {
  /// Selected project filter; null shows every project.
  int? _projectId;

  /// Month shown in the overtime card (year and month only).
  DateTime _overtimeMonth = DateTime(DateTime.now().year, DateTime.now().month);

  /// Projects that have entries, named from the entries or the assigned list.
  List<Project> _filterOptions(List<TimeEntry> entries, List<Project>? assigned) {
    final byId = {for (final p in assigned ?? const <Project>[]) p.id: p};
    final options = <int, Project>{};
    for (final e in entries) {
      final project = e.project ?? byId[e.projectId];
      if (project != null) options[e.projectId] = project;
    }
    return options.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  /// A locally kept entry shaped like a server one, for the shared list.
  TimeEntry _asEntry(PendingEntry p, WorkspaceSession session) {
    final project = session.projects.data?.where((x) => x.id == p.projectId).firstOrNull ??
        Project(id: p.projectId, name: p.projectName, color: Colors.grey, status: 'active');
    final tags = {for (final t in session.tags.data ?? const <Tag>[]) t.id: t};
    return TimeEntry(
      id: -1,
      projectId: p.projectId,
      project: project,
      taskTitle: p.taskTitle,
      description: p.description,
      totalMinutes: p.minutes,
      date: p.date,
      billable: p.billable,
      tags: [for (final id in p.tagIds) if (tags[id] != null) tags[id]!],
      createdAt: p.createdAt,
    );
  }

  Future<void> _upload(TrackerController tracker, String id) async {
    final messenger = ScaffoldMessenger.of(context);
    final error = await tracker.uploadLocal(id);
    if (error != null) messenger.showSnackBar(SnackBar(content: Text("Couldn't upload: $error")));
  }

  Future<void> _uploadAll(TrackerController tracker) async {
    final messenger = ScaffoldMessenger.of(context);
    final count = tracker.local.length;
    final error = await tracker.uploadAllLocal();
    messenger.showSnackBar(SnackBar(
      content: Text(error == null
          ? 'Uploaded $count ${count == 1 ? 'entry' : 'entries'} to Time-Wise.'
          : "Couldn't upload: $error"),
    ));
  }

  Future<void> _edit(TimeEntry entry, PendingEntry? local) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await showEntryEditor(context, entry: entry, local: local);
    if (result == null) return;
    messenger.showSnackBar(SnackBar(
      content: Text(result == EntryEditResult.deleted ? 'Entry deleted.' : 'Entry updated.'),
    ));
  }

  /// Adds time by hand, without the timer.
  Future<void> _addTime() => addTimeManually(context);

  /// Time-Wise entries being deleted, to show a spinner in their row.
  final Set<int> _deleting = {};

  /// Entries being copied to Time-Wise: Time-Wise ids, or local entry ids.
  final Set<Object> _copying = {};

  /// Copies [entry] (or the [local] one behind it) to today, either straight
  /// into Time-Wise or kept on this Mac.
  Future<void> _copyForToday(
    WorkspaceSession session,
    TrackerController tracker,
    TimeEntry entry,
    PendingEntry? local, {
    required bool toTimeWise,
  }) async {
    final key = local?.id ?? entry.id;
    if (_copying.contains(key)) return;
    final today = dateKey(DateTime.now());
    final payload = local != null
        ? {...local.payload, 'date': today}
        : WorkspaceSession.entryPayload(entry, date: today);
    final projectName = local?.projectName ?? entry.project?.name ?? '';
    final messenger = ScaffoldMessenger.of(context);
    final duration = local != null && local.underAMinute
        ? '${local.seconds ?? 0}s'
        : formatMinutes(entry.totalMinutes);

    if (!toTimeWise) {
      tracker.addLocal(payload, projectName: projectName, seconds: local?.seconds);
      messenger.showSnackBar(SnackBar(
        content: Text('Copied "${entry.taskTitle}" ($duration) to today, on this Mac.'),
      ));
      return;
    }

    setState(() => _copying.add(key));
    try {
      // Under a minute goes up as Time-Wise's minimum of one minute.
      await session.createEntry(
        local != null && local.underAMinute ? {...payload, 'minutes': 1} : payload,
      );
      messenger.showSnackBar(SnackBar(
        content: Text('Copied "${entry.taskTitle}" ($duration) to today in Time-Wise.'),
      ));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text("Couldn't copy: ${e.message}")));
    } finally {
      if (mounted) setState(() => _copying.remove(key));
    }
  }

  /// After a confirmed delete, the snackbar still offers Undo.
  SnackBar _deletedSnackBar(String message, VoidCallback onUndo) => SnackBar(
        content: Text(message),
        persist: false,
        duration: const Duration(seconds: 5),
        action: SnackBarAction(label: 'Undo', onPressed: onUndo),
      );

  /// Asks before deleting; [where] is "Time-Wise" or "this Mac".
  Future<bool> _confirmDelete({
    required String where,
    required String duration,
    required String title,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete from $where?'),
        content: Text('$duration on "$title" will be deleted.'),
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
    return ok == true;
  }

  Future<void> _deleteLocal(TrackerController tracker, PendingEntry entry) async {
    final confirmed = await _confirmDelete(
      where: 'this Mac',
      duration: entry.underAMinute ? '${entry.seconds ?? 0}s' : formatMinutes(entry.minutes),
      title: entry.taskTitle,
    );
    if (!confirmed || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final index = tracker.local.indexWhere((e) => e.id == entry.id);
    tracker.deleteLocal(entry.id);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(_deletedSnackBar(
      'Deleted "${entry.taskTitle}" from this Mac.',
      () => tracker.restoreLocal(entry, index),
    ));
  }

  Future<void> _deleteServer(WorkspaceSession session, TimeEntry entry) async {
    if (_deleting.contains(entry.id)) return;
    final confirmed = await _confirmDelete(
      where: 'Time-Wise',
      duration: formatMinutes(entry.totalMinutes),
      title: entry.taskTitle,
    );
    if (!confirmed || !mounted || _deleting.contains(entry.id)) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _deleting.add(entry.id));
    try {
      await session.deleteEntry(entry.id);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(_deletedSnackBar(
        'Deleted "${entry.taskTitle}" from Time-Wise.',
        () async {
          try {
            await session.restoreEntry(entry);
          } on ApiException catch (e) {
            messenger.showSnackBar(SnackBar(content: Text("Couldn't undo: ${e.message}")));
          }
        },
      ));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text("Couldn't delete: ${e.message}")));
    } finally {
      if (mounted) setState(() => _deleting.remove(entry.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<WorkspaceSession>();
    final tracker = context.watch<TrackerController>();
    final entries = session.entries;
    final list = entries.data;

    // Server entries plus those kept on this Mac. Local ones still show when
    // Time-Wise can't be reached; that's when they matter most.
    final serverFailed = list == null && entries.error != null;
    final localOf = Map<TimeEntry, PendingEntry>.identity();
    List<TimeEntry>? all;
    if (list != null || serverFailed) {
      for (final p in tracker.local) {
        localOf[_asEntry(p, session)] = p;
      }
      all = [...localOf.keys, ...?list]
        ..sort((a, b) {
          final byDate = b.date.compareTo(a.date);
          if (byDate != 0) return byDate;
          return (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0));
        });
    }

    // Overtime is about the whole day, so it counts every project (and local
    // entries), whatever the filter shows.
    final byDay = all == null ? const <String, int>{} : minutesByDay(all);
    final overtimeByDay = {
      for (final day in byDay.entries)
        if (dailyOvertime(day.value) > 0) day.key: dailyOvertime(day.value),
    };
    final thisMonth = DateTime(DateTime.now().year, DateTime.now().month);
    final firstMonth = byDay.isEmpty
        ? thisMonth
        : byDay.keys.map(parseDateKey).reduce((a, b) => a.isBefore(b) ? a : b);
    final earliest = DateTime(firstMonth.year, firstMonth.month);

    final options = all == null ? const <Project>[] : _filterOptions(all, session.projects.data);
    // A project can drop out of the list after a refresh.
    final selected = options.where((p) => p.id == _projectId).firstOrNull;
    final shown = all == null || selected == null
        ? all
        : [for (final e in all) if (e.projectId == selected.id) e];

    Widget body;
    if (shown == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (shown.isEmpty) {
      body = serverFailed
          ? ErrorState(message: entries.error!, onRetry: session.loadEntries)
          : EmptyState(
              icon: Icons.hourglass_empty,
              message: selected == null
                  ? 'No time tracked yet.\nStart the timer and your entries will show up here.'
                  : 'No time tracked on ${selected.name} yet.',
            );
    } else {
      body = _EntryList(
        entries: shown,
        overtimeByDay: overtimeByDay,
        localOf: localOf,
        uploading: tracker.uploadingLocal,
        onUpload: (p) => _upload(tracker, p.id),
        deleting: _deleting,
        copying: _copying,
        onCopy: (e, p, toTimeWise) =>
            _copyForToday(session, tracker, e, p, toTimeWise: toTimeWise),
        onDeleteLocal: (p) => _deleteLocal(tracker, p),
        onDeleteServer: (e) => _deleteServer(session, e),
        onEdit: _edit,
      );
    }

    final localMinutes = tracker.local.fold<int>(0, (sum, p) => sum + p.minutes);
    final localCount = tracker.local.length;

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 6, 0),
              child: Row(
                children: [
                  Expanded(
                    child: _ProjectFilter(
                      options: options,
                      selected: selected,
                      enabled: all != null && options.isNotEmpty,
                      onChanged: (id) => setState(() => _projectId = id),
                    ),
                  ),
                  if (entries.loading && list != null)
                    const Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                  IconButton(
                    tooltip: 'Add time',
                    iconSize: 20,
                    onPressed: session.trackableProjects.isEmpty ? null : _addTime,
                    icon: const Icon(Icons.add),
                  ),
                  IconButton(
                    tooltip: 'Refresh',
                    iconSize: 18,
                    onPressed: entries.loading ? null : session.loadEntries,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
            ),
            if (shown != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
                child: _Totals(entries: shown),
              ),
            if (all != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                child: _OvertimeCard(
                  month: _overtimeMonth,
                  stats: monthOvertime(byDay, _overtimeMonth),
                  onPrevious: _overtimeMonth.isAfter(earliest)
                      ? () => setState(() => _overtimeMonth =
                          DateTime(_overtimeMonth.year, _overtimeMonth.month - 1))
                      : null,
                  onNext: _overtimeMonth.isBefore(thisMonth)
                      ? () => setState(() => _overtimeMonth =
                          DateTime(_overtimeMonth.year, _overtimeMonth.month + 1))
                      : null,
                ),
              ),
            if (localCount > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: InlineNotice(
                  icon: Icons.laptop_mac_outlined,
                  message: '$localCount ${localCount == 1 ? 'entry' : 'entries'} '
                      '(${formatMinutes(localMinutes)}) only on this Mac, not in Time-Wise yet.',
                  trailing: tracker.uploadingLocal.isEmpty
                      ? null
                      : const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                  actions: [
                    TextButton.icon(
                      onPressed: tracker.uploadingLocal.isEmpty ? () => _uploadAll(tracker) : null,
                      icon: const Icon(Icons.cloud_upload_outlined, size: 16),
                      label: const Text('Upload all'),
                    ),
                  ],
                ),
              ),
            if (entries.error != null && !(shown?.isEmpty ?? true))
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: InlineNotice(
                  message: list == null
                      ? "Couldn't load Time-Wise entries: ${entries.error}"
                      : "Couldn't refresh: ${entries.error}",
                  icon: Icons.error_outline,
                  isError: true,
                  actions: [TextButton(onPressed: session.loadEntries, child: const Text('Retry'))],
                ),
              ),
            const SizedBox(height: 10),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}

/// "All projects" or one project, as a dense dropdown.
class _ProjectFilter extends StatelessWidget {
  const _ProjectFilter({
    required this.options,
    required this.selected,
    required this.enabled,
    required this.onChanged,
  });

  static const _all = -1;

  final List<Project> options;
  final Project? selected;
  final bool enabled;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final value = selected?.id ?? _all;

    Widget label(Project? p) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (p == null)
              Icon(Icons.layers_outlined, size: 14, color: scheme.onSurfaceVariant)
            else
              ColorDot(p.color, size: 8),
            const SizedBox(width: 8),
            Flexible(
              child: Text(p?.name ?? 'All projects', maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        );

    return DropdownButtonFormField<int>(
      // Re-keyed so a filter dropped after a refresh resets the field.
      key: ValueKey(value),
      initialValue: value,
      isExpanded: true,
      isDense: true,
      decoration: const InputDecoration(
        prefixIcon: Icon(Icons.filter_list, size: 18),
        prefixIconConstraints: BoxConstraints(minWidth: 36, minHeight: 34),
      ),
      items: [
        DropdownMenuItem(value: _all, child: label(null)),
        for (final p in options) DropdownMenuItem(value: p.id, child: label(p)),
      ],
      selectedItemBuilder: (context) => [
        Align(alignment: Alignment.centerLeft, child: label(null)),
        for (final p in options) Align(alignment: Alignment.centerLeft, child: label(p)),
      ],
      onChanged: enabled ? (id) => onChanged(id == null || id == _all ? null : id) : null,
    );
  }
}

class _Totals extends StatelessWidget {
  const _Totals({required this.entries});

  final List<TimeEntry> entries;

  @override
  Widget build(BuildContext context) {
    final today = dateOnly(DateTime.now());
    final weekStart = today.subtract(Duration(days: today.weekday - DateTime.monday));
    final monthStart = DateTime(today.year, today.month);
    var todayMinutes = 0;
    var weekMinutes = 0;
    var monthMinutes = 0;
    for (final e in entries) {
      final day = parseDateKey(e.date);
      if (day.isAfter(today)) continue;
      if (day == today) todayMinutes += e.totalMinutes;
      if (!day.isBefore(weekStart)) weekMinutes += e.totalMinutes;
      if (!day.isBefore(monthStart)) monthMinutes += e.totalMinutes;
    }
    return Row(
      children: [
        Expanded(child: _Total(label: 'Today', minutes: todayMinutes)),
        const SizedBox(width: 12),
        Expanded(child: _Total(label: 'This week', minutes: weekMinutes)),
        const SizedBox(width: 12),
        Expanded(child: _Total(label: 'This month', minutes: monthMinutes)),
      ],
    );
  }
}

class _Total extends StatelessWidget {
  const _Total({required this.label, required this.minutes});

  final String label;
  final int minutes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            formatMinutes(minutes),
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}

/// Entries grouped under a header per day, with the day's total.
class _EntryList extends StatelessWidget {
  const _EntryList({
    required this.entries,
    required this.overtimeByDay,
    required this.localOf,
    required this.uploading,
    required this.onUpload,
    required this.deleting,
    required this.copying,
    required this.onCopy,
    required this.onDeleteLocal,
    required this.onDeleteServer,
    required this.onEdit,
  });

  /// Already sorted newest day first.
  final List<TimeEntry> entries;

  /// The local record behind each entry that is only on this Mac.
  final Map<TimeEntry, PendingEntry> localOf;
  final Set<String> uploading;
  final ValueChanged<PendingEntry> onUpload;
  final ValueChanged<PendingEntry> onDeleteLocal;

  /// Ids of Time-Wise entries being deleted.
  final Set<int> deleting;
  final ValueChanged<TimeEntry> onDeleteServer;

  /// Entries being copied to Time-Wise (Time-Wise ids or local ids).
  final Set<Object> copying;

  /// "Copy for today": into Time-Wise when `toTimeWise`, else on this Mac.
  final void Function(TimeEntry entry, PendingEntry? local, bool toTimeWise) onCopy;

  /// Opens the editor; `local` is set for entries only on this Mac.
  final void Function(TimeEntry entry, PendingEntry? local) onEdit;

  /// Overtime per day (`yyyy-MM-dd`), across all projects.
  final Map<String, int> overtimeByDay;

  Widget _row(TimeEntry entry) {
    final local = localOf[entry];
    final short = local != null && local.underAMinute;
    return _EntryRow(
      entry: entry,
      durationText: short ? '${local?.seconds ?? 0}s' : formatMinutes(entry.totalMinutes),
      uploadTooltip: short ? 'Upload to Time-Wise as 1m (its minimum)' : 'Upload to Time-Wise',
      local: local != null,
      busy: copying.contains(local?.id ?? entry.id) ||
          (local != null ? uploading.contains(local.id) : deleting.contains(entry.id)),
      onUpload: local == null ? null : () => onUpload(local),
      onCopy: (toTimeWise) => onCopy(entry, local, toTimeWise),
      onDelete: local == null ? () => onDeleteServer(entry) : () => onDeleteLocal(local),
      // Not while it's being uploaded or deleted.
      onTap: (local != null ? uploading.contains(local.id) : deleting.contains(entry.id))
          ? null
          : () => onEdit(entry, local),
    );
  }

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<TimeEntry>>{};
    for (final e in entries) {
      groups.putIfAbsent(e.date, () => []).add(e);
    }
    final days = groups.keys.toList();
    final dayStyle = Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700);

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      itemCount: days.length,
      itemBuilder: (context, i) {
        final day = days[i];
        final items = groups[day]!;
        final total = items.fold<int>(0, (sum, e) => sum + e.totalMinutes);
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(2, 0, 2, 4),
                child: Row(
                  children: [
                    Expanded(child: Text(formatDay(parseDateKey(day)), style: dayStyle)),
                    if ((overtimeByDay[day] ?? 0) > 0) ...[
                      _OvertimeBadge(minutes: overtimeByDay[day]!),
                      const SizedBox(width: 8),
                    ],
                    Text(formatMinutes(total), style: dayStyle),
                  ],
                ),
              ),
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    for (var j = 0; j < items.length; j++) ...[
                      if (j > 0) const Divider(height: 1),
                      _row(items[j]),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.entry,
    required this.durationText,
    this.uploadTooltip = 'Upload to Time-Wise',
    this.local = false,
    this.busy = false,
    this.onUpload,
    this.onCopy,
    this.onDelete,
    this.onTap,
  });

  final TimeEntry entry;

  /// Opens the editor.
  final VoidCallback? onTap;

  /// "1h 30m", or "45s" for a local entry under a minute.
  final String durationText;
  final String uploadTooltip;

  /// Only on this Mac: shows upload and delete instead of the saved mark.
  final bool local;

  /// Being uploaded or deleted: a spinner replaces the actions.
  final bool busy;
  final VoidCallback? onUpload;

  /// "Copy for today": `true` saves the copy to Time-Wise, `false` keeps it
  /// on this Mac.
  final ValueChanged<bool>? onCopy;
  final VoidCallback? onDelete;

  static const _compact = BoxConstraints.tightFor(width: 28, height: 28);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final project = entry.project;
    final description = entry.description?.trim();
    final subtitle = [
      if (project != null) project.name,
      if (description != null && description.isNotEmpty) description,
    ].join(' · ');

    return Material(
      color: local ? scheme.tertiaryContainer.withValues(alpha: 0.25) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: ColorDot(project?.color ?? scheme.outline, size: 8),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.taskTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: muted),
                      ),
                    if (entry.tags.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Wrap(
                        spacing: 8,
                        runSpacing: 2,
                        children: [
                          for (final tag in entry.tags)
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ColorDot(tag.color, size: 6),
                                const SizedBox(width: 4),
                                Text(tag.name, style: theme.textTheme.labelSmall),
                              ],
                            ),
                        ],
                      ),
                    ],
                    if (local) ...[
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Icon(Icons.laptop_mac_outlined, size: 12, color: scheme.tertiary),
                          const SizedBox(width: 4),
                          Text(
                            'Only on this Mac',
                            style: theme.textTheme.labelSmall?.copyWith(color: scheme.tertiary),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Text(
                      durationText,
                      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (entry.billable)
                        Tooltip(
                          message: 'Billable',
                          child: Icon(Icons.attach_money, size: 14, color: scheme.primary),
                        ),
                      if (busy)
                        const Padding(
                          padding: EdgeInsets.all(7),
                          child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                        )
                      else ...[
                        if (!local)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Tooltip(
                              message: 'Saved in Time-Wise',
                              child: Icon(Icons.cloud_done_outlined, size: 14, color: muted),
                            ),
                          ),
                        if (onCopy != null) _CopyForTodayButton(onCopy: onCopy!, constraints: _compact),
                        IconButton(
                          tooltip: local ? 'Delete from this Mac' : 'Delete from Time-Wise',
                          onPressed: onDelete,
                          constraints: _compact,
                          padding: EdgeInsets.zero,
                          iconSize: 16,
                          color: muted,
                          icon: const Icon(Icons.delete_outline),
                        ),
                        if (local)
                          IconButton(
                            tooltip: uploadTooltip,
                            onPressed: onUpload,
                            constraints: _compact,
                            padding: EdgeInsets.zero,
                            iconSize: 18,
                            color: scheme.primary,
                            icon: const Icon(Icons.cloud_upload_outlined),
                          ),
                      ],
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Overtime for one month, with arrows to step through months.
class _OvertimeCard extends StatelessWidget {
  const _OvertimeCard({
    required this.month,
    required this.stats,
    required this.onPrevious,
    required this.onNext,
  });

  final DateTime month;
  final MonthOvertime stats;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final hasOvertime = stats.overtimeMinutes > 0;
    final accent = hasOvertime ? scheme.tertiary : muted;
    final days = stats.overtimeDays;

    return Tooltip(
      message: 'Time beyond 8h a day, all projects',
      waitDuration: const Duration(milliseconds: 600),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: scheme.tertiaryContainer.withValues(alpha: hasOvertime ? 0.35 : 0.12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: scheme.tertiary.withValues(alpha: hasOvertime ? 0.4 : 0.15)),
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Previous month',
              iconSize: 18,
              icon: const Icon(Icons.chevron_left),
              onPressed: onPrevious,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.more_time, size: 13, color: accent),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          'Overtime · ${DateFormat('MMMM y').format(month)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(color: muted),
                        ),
                      ),
                    ],
                  ),
                  Text(
                    formatMinutes(stats.overtimeMinutes),
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: accent,
                      height: 1.2,
                    ),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${formatMinutes(stats.workedMinutes)} worked',
                  style: theme.textTheme.labelSmall?.copyWith(color: muted),
                ),
                Text(
                  days == 0 ? 'No day over 8h' : '$days ${days == 1 ? 'day' : 'days'} over 8h',
                  style: theme.textTheme.labelSmall?.copyWith(color: muted),
                ),
              ],
            ),
            IconButton(
              tooltip: 'Next month',
              iconSize: 18,
              icon: const Icon(Icons.chevron_right),
              onPressed: onNext,
            ),
          ],
        ),
      ),
    );
  }
}

/// "+1h overtime" next to a day that went over 8h.
class _OvertimeBadge extends StatelessWidget {
  const _OvertimeBadge({required this.minutes});

  final int minutes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Tooltip(
      message: 'Over 8h that day (all projects)',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: scheme.tertiaryContainer.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          '+${formatMinutes(minutes)} overtime',
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.tertiary,
            fontWeight: FontWeight.w700,
            fontSize: 10,
          ),
        ),
      ),
    );
  }
}

/// Copy icon with a menu: copy the entry to today in Time-Wise or on this Mac.
class _CopyForTodayButton extends StatelessWidget {
  const _CopyForTodayButton({required this.onCopy, required this.constraints});

  final ValueChanged<bool> onCopy;
  final BoxConstraints constraints;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;

    Widget option(String title, String subtitle) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            Text(subtitle, style: theme.textTheme.labelSmall?.copyWith(color: muted)),
          ],
        );

    return MenuAnchor(
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(Icons.cloud_upload_outlined, size: 20),
          onPressed: () => onCopy(true),
          child: option('Copy to Time-Wise', 'Dated today, upload now'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.laptop_mac_outlined, size: 20),
          onPressed: () => onCopy(false),
          child: option('Copy on this Mac', 'Dated today, upload later'),
        ),
      ],
      builder: (context, menu, _) => IconButton(
        tooltip: 'Copy for today',
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
        constraints: constraints,
        padding: EdgeInsets.zero,
        iconSize: 15,
        color: muted,
        icon: const Icon(Icons.content_copy),
      ),
    );
  }
}
