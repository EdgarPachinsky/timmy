import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../models/models.dart';
import '../../state/workspace_session.dart';
import '../../widgets/common.dart';

class EntriesPage extends StatelessWidget {
  const EntriesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<WorkspaceSession>();
    final entries = session.entries;
    final list = entries.data;

    Widget body;
    if (list == null) {
      body = entries.error != null
          ? ErrorState(message: entries.error!, onRetry: session.loadEntries)
          : const Center(child: CircularProgressIndicator());
    } else if (list.isEmpty) {
      body = const EmptyState(
        icon: Icons.hourglass_empty,
        message: 'No time tracked yet.\nStart the timer and your entries will show up here.',
      );
    } else {
      body = _EntryList(entries: list);
    }

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 6, 0),
              child: Row(
                children: [
                  Expanded(child: list == null ? const SizedBox.shrink() : _Totals(entries: list)),
                  if (entries.loading && list != null)
                    const Padding(
                      padding: EdgeInsets.only(right: 6),
                      child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
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
            if (list != null && entries.error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: InlineNotice(
                  message: "Couldn't refresh: ${entries.error}",
                  icon: Icons.error_outline,
                  isError: true,
                  actions: [TextButton(onPressed: session.loadEntries, child: const Text('Retry'))],
                ),
              ),
            const SizedBox(height: 8),
            Expanded(child: body),
          ],
        ),
      ),
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
    var todayMinutes = 0;
    var weekMinutes = 0;
    for (final e in entries) {
      final day = parseDateKey(e.date);
      if (day == today) todayMinutes += e.totalMinutes;
      if (!day.isBefore(weekStart) && !day.isAfter(today)) weekMinutes += e.totalMinutes;
    }
    return Row(
      children: [
        _Total(label: 'Today', minutes: todayMinutes),
        const SizedBox(width: 20),
        _Total(label: 'This week', minutes: weekMinutes),
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
        Text(label, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        Text(
          formatMinutes(minutes),
          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

/// Entries grouped under a header per day, with the day's total.
class _EntryList extends StatelessWidget {
  const _EntryList({required this.entries});

  /// Already sorted newest day first.
  final List<TimeEntry> entries;

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
                      _EntryRow(entry: items[j]),
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
  const _EntryRow({required this.entry});

  final TimeEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final project = entry.project;
    final description = entry.description?.trim();
    final subtitle = [
      if (project != null) project.name,
      if (description != null && description.isNotEmpty) description,
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
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
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                formatMinutes(entry.totalMinutes),
                style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (entry.billable) Icon(Icons.attach_money, size: 14, color: scheme.primary),
            ],
          ),
        ],
      ),
    );
  }
}
