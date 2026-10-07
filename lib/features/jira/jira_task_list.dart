import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/format.dart';
import '../../core/jira_client.dart';
import '../../models/jira.dart';
import '../../state/jira_controller.dart';
import '../../widgets/common.dart';
import 'jira_status_menu.dart';

/// Issues sharing a status (a board column).
class _StatusGroup {
  _StatusGroup(this.status, this.category);

  final String status;
  final String category;
  final List<JiraIssue> issues = [];
}

/// In-progress columns first, then to-do, then anything else, then done.
int _categoryRank(String category) => switch (category) {
      'indeterminate' => 0,
      'new' => 1,
      'done' => 3,
      _ => 2,
    };

/// Groups [issues] by status. Within a group the most urgent come first,
/// otherwise Jira's order (recently updated first) is kept.
List<_StatusGroup> _groupByStatus(List<JiraIssue> issues) {
  final groups = <String, _StatusGroup>{};
  for (final issue in issues) {
    final status = issue.status.isEmpty ? 'No status' : issue.status;
    groups.putIfAbsent(status, () => _StatusGroup(status, issue.statusCategory)).issues.add(issue);
  }
  final ordered = groups.values.toList();
  _stableSort(ordered, (a, b) => _categoryRank(a.category).compareTo(_categoryRank(b.category)));
  for (final group in ordered) {
    _stableSort(group.issues, (a, b) => a.priorityRank.compareTo(b.priorityRank));
  }
  return ordered;
}

/// [List.sort] isn't stable; ties keep their original order here.
void _stableSort<T>(List<T> list, int Function(T, T) compare) {
  final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
  indexed.sort((a, b) {
    final c = compare(a.$2, b.$2);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  for (var i = 0; i < list.length; i++) {
    list[i] = indexed[i].$2;
  }
}

/// Column color by status category: blue in progress, green done, grey to do.
Color jiraStatusColor(String category, ColorScheme scheme) => switch (category) {
      'indeterminate' => const Color(0xFF579DFF),
      'done' => const Color(0xFF22A06B),
      _ => scheme.outline,
    };

/// Search box, priority and type filters, and Jira tasks grouped by status
/// (collapsible), with an optional header ([title], task count, [trailing]).
/// Right-clicking a task moves it to another column. Used by the tracker's
/// picker and the Jira tasks page.
class JiraTaskList extends StatefulWidget {
  const JiraTaskList({
    super.key,
    required this.jira,
    required this.onSelected,
    this.title,
    this.trailing,
  });

  final JiraController jira;
  final ValueChanged<JiraIssue> onSelected;
  final String? title;
  final Widget? trailing;

  @override
  State<JiraTaskList> createState() => JiraTaskListState();
}

class JiraTaskListState extends State<JiraTaskList> {
  final _query = TextEditingController();
  Timer? _debounce;
  List<JiraIssue>? _issues;
  String? _error;
  bool _loading = false;

  /// Ignores answers to searches that were overtaken by newer typing.
  int _searchId = 0;

  @override
  void initState() {
    super.initState();
    _search(refresh: true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _onTyped(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _search);
  }

  Future<void> _search({bool refresh = false}) async {
    _debounce?.cancel();
    final id = ++_searchId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final issues = await widget.jira.findTasks(_query.text, refresh: refresh);
      if (!mounted || id != _searchId) return;
      setState(() => _issues = issues);
    } on JiraException catch (e) {
      if (!mounted || id != _searchId) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted && id == _searchId) setState(() => _loading = false);
    }
  }

  bool get _searching => _query.text.trim().isNotEmpty;

  /// Reloads from Jira, keeping the search text and filters.
  void refresh() => _search(refresh: true);

  Future<void> _move(JiraIssue issue, Offset globalPosition) async {
    final moved = await moveJiraIssue(
      context,
      widget.jira,
      issue,
      position: menuPositionAt(context, globalPosition),
    );
    if (moved != null && mounted) refresh();
  }

  bool _passesFilters(JiraIssue issue) {
    final priorities = widget.jira.priorityFilter;
    final types = widget.jira.typeFilter;
    return (priorities.isEmpty || priorities.contains(issue.priority)) &&
        (types.isEmpty || types.contains(issue.issueType));
  }

  void _toggleFilter(Set<String> set, String value) => setState(() {
        if (!set.remove(value)) set.add(value);
      });

  void _clearFilters() => setState(() {
        widget.jira.priorityFilter.clear();
        widget.jira.typeFilter.clear();
      });

  /// Search results are short, so they're all shown open. Otherwise the
  /// user's last choice wins; by default in-progress columns are open (or the
  /// first column, if nothing is in progress, or everything for a short list).
  bool _isExpanded(_StatusGroup group, List<_StatusGroup> groups, int total) {
    if (_searching) return true;
    final remembered = widget.jira.pickerExpanded[group.status];
    if (remembered != null) return remembered;
    if (total <= 6) return true;
    if (groups.any((g) => g.category == 'indeterminate')) return group.category == 'indeterminate';
    return identical(group, groups.first);
  }

  void _toggle(_StatusGroup group, bool expanded) {
    setState(() => widget.jira.pickerExpanded[group.status] = !expanded);
  }

  /// A group's header, then its issues when open.
  List<Widget> _groupRows(_StatusGroup group, List<_StatusGroup> groups, int total) {
    final expanded = _isExpanded(group, groups, total);
    return [
      _GroupHeader(
        group: group,
        expanded: expanded,
        // Search results are all shown, so there's nothing to collapse.
        onTap: _searching ? null : () => _toggle(group, expanded),
      ),
      if (expanded)
        for (var i = 0; i < group.issues.length; i++) ...[
          if (i > 0) const Divider(height: 1, indent: 12, endIndent: 12),
          _IssueTile(
            issue: group.issues[i],
            myAccountId: widget.jira.accountId,
            onTap: () => widget.onSelected(group.issues[i]),
            onMove: (position) => _move(group.issues[i], position),
          ),
        ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final loaded = _issues;
    final issues = loaded?.where(_passesFilters).toList();
    final filtering = widget.jira.priorityFilter.isNotEmpty || widget.jira.typeFilter.isNotEmpty;

    // Filter choices: what the loaded tasks have, plus anything still selected.
    final priorities = {...?loaded?.map((i) => i.priority), ...widget.jira.priorityFilter}.toList()
      ..sort((a, b) {
        final byRank = jiraPriorityRank(a).compareTo(jiraPriorityRank(b));
        return byRank != 0 ? byRank : a.compareTo(b);
      });
    final types = {...?loaded?.map((i) => i.issueType), ...widget.jira.typeFilter}.toList()..sort();

    Widget body;
    if (_error != null) {
      body = ErrorState(message: _error!, onRetry: () => _search(refresh: true));
    } else if (issues == null) {
      body = const SizedBox.shrink();
    } else if (issues.isEmpty && loaded!.isNotEmpty) {
      body = EmptyState(icon: Icons.filter_alt_off_outlined, message: 'No tasks match these filters.');
    } else if (issues.isEmpty) {
      body = EmptyState(
        icon: Icons.search_off,
        message: _searching
            ? 'No Jira tasks match "${_query.text.trim()}".'
            : 'No open Jira tasks are assigned to you.',
      );
    } else {
      final groups = _groupByStatus(issues);
      body = ListView(
        padding: const EdgeInsets.only(bottom: 8),
        children: [
          for (final group in groups) ..._groupRows(group, groups, issues.length),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 4, 0),
            child: Row(
              children: [
                Text(
                  widget.title!,
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                if (issues != null && issues.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  _CountPill(count: issues.length),
                ],
                const Spacer(),
                if (widget.trailing != null) widget.trailing!,
              ],
            ),
          ),
        Padding(
          padding: EdgeInsets.fromLTRB(12, widget.title != null ? 2 : 10, 12, 8),
          child: TextField(
            controller: _query,
            autofocus: true,
            onChanged: _onTyped,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              hintText: 'Search title or description, or a key',
              prefixIcon: const Icon(Icons.search, size: 18),
              prefixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 34),
              suffixIcon: widget.title == null && issues != null
                  ? Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: Center(widthFactor: 1, child: _CountPill(count: issues.length)),
                    )
                  : null,
            ),
          ),
        ),
        SizedBox(
          height: 34,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            children: [
              _FilterMenu(
                label: 'Priority',
                options: priorities,
                selected: widget.jira.priorityFilter,
                optionLabel: (p) => p.isEmpty ? 'No priority' : p,
                optionIcon: (p) => p.isEmpty ? null : JiraPriority(name: p, iconOnly: true),
                onToggle: (p) => _toggleFilter(widget.jira.priorityFilter, p),
              ),
              const SizedBox(width: 6),
              _FilterMenu(
                label: 'Type',
                options: types,
                selected: widget.jira.typeFilter,
                optionLabel: (t) => t.isEmpty ? 'No type' : t,
                optionIcon: (t) => JiraTypeIcon(type: t),
                onToggle: (t) => _toggleFilter(widget.jira.typeFilter, t),
              ),
              if (filtering) ...[
                const SizedBox(width: 2),
                TextButton(onPressed: _clearFilters, child: const Text('Clear')),
              ],
            ],
          ),
        ),
        SizedBox(
          height: 2,
          child: _loading ? const LinearProgressIndicator(minHeight: 2) : null,
        ),
        Divider(height: 1, color: scheme.outlineVariant),
        Expanded(child: body),
      ],
    );
  }
}

class _CountPill extends StatelessWidget {
  const _CountPill({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text('$count', style: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600)),
    );
  }
}

/// Collapsible status header: chevron, column color, name and count.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.group, required this.expanded, required this.onTap});

  final _StatusGroup group;
  final bool expanded;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = jiraStatusColor(group.category, scheme);
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 7, 12, 7),
          child: Row(
            children: [
              AnimatedRotation(
                turns: expanded ? 0 : -0.25,
                duration: const Duration(milliseconds: 150),
                child: Icon(Icons.expand_more, size: 18, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(width: 4),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  group.status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              _CountPill(count: group.issues.length),
            ],
          ),
        ),
      ),
    );
  }
}

/// One issue: type, key, priority and how long it's been yours; then the
/// title and a short description.
class _IssueTile extends StatelessWidget {
  const _IssueTile({
    required this.issue,
    required this.myAccountId,
    required this.onTap,
    required this.onMove,
  });

  final JiraIssue issue;
  final String? myAccountId;
  final VoidCallback onTap;

  /// Right-click: move to another column, with the menu at that point.
  final ValueChanged<Offset> onMove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final assignedAt = issue.assigneeAccountId != null && issue.assigneeAccountId == myAccountId
        ? issue.assignedAt
        : null;

    return InkWell(
      onTap: onTap,
      onSecondaryTapDown: (details) => onMove(details.globalPosition),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 9),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                JiraTypeIcon(type: issue.issueType),
                const SizedBox(width: 5),
                Text(
                  issue.key,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (issue.priority.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  JiraPriority(name: issue.priority),
                ],
                const Spacer(),
                if (assignedAt != null) JiraAssignedAge(since: assignedAt),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              issue.summary.isEmpty ? '(no title)' : issue.summary,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, height: 1.25),
            ),
            if (issue.description.isNotEmpty) ...[
              const SizedBox(height: 1),
              Text(
                issue.description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Small Jira-like icon for the issue type, named in its tooltip.
class JiraTypeIcon extends StatelessWidget {
  const JiraTypeIcon({super.key, required this.type});

  final String type;

  @override
  Widget build(BuildContext context) {
    final name = type.toLowerCase();
    final (icon, color) = switch (name) {
      _ when name.contains('bug') => (Icons.bug_report, const Color(0xFFE5493A)),
      _ when name.contains('sub') => (Icons.subdirectory_arrow_right, const Color(0xFF579DFF)),
      _ when name.contains('story') => (Icons.bookmark, const Color(0xFF63BA3C)),
      _ when name.contains('epic') => (Icons.bolt, const Color(0xFF9F8FEF)),
      _ => (Icons.check_box, const Color(0xFF4BADE8)),
    };
    return Tooltip(
      message: type.isEmpty ? 'Issue' : type,
      child: Icon(icon, size: 14, color: color),
    );
  }
}

/// Priority arrow plus its name, colored like Jira's.
class JiraPriority extends StatelessWidget {
  const JiraPriority({super.key, required this.name, this.iconOnly = false});

  final String name;

  /// Just the arrow, e.g. inside a menu that already names it.
  final bool iconOnly;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (jiraPriorityRank(name)) {
      0 => (Icons.keyboard_double_arrow_up, const Color(0xFFE5493A)),
      1 => (Icons.keyboard_arrow_up, const Color(0xFFF07A4A)),
      3 => (Icons.keyboard_arrow_down, const Color(0xFF579DFF)),
      4 => (Icons.keyboard_double_arrow_down, const Color(0xFF8C9BAB)),
      _ => (Icons.drag_handle, const Color(0xFFE2B203)),
    };
    if (iconOnly) return Icon(icon, size: 16, color: color);
    return Tooltip(
      message: '$name priority',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 1),
          Text(
            name,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// "Assigned today" / "Assigned 5d ago", with the exact date on hover.
class JiraAssignedAge extends StatelessWidget {
  const JiraAssignedAge({super.key, required this.since});

  final DateTime since;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final local = since.toLocal();
    final days = dateOnly(DateTime.now()).difference(dateOnly(local)).inDays;
    final text = days <= 0 ? 'Assigned today' : 'Assigned ${days}d ago';
    final muted = theme.colorScheme.onSurfaceVariant;
    return Tooltip(
      message: 'Assigned to you on ${DateFormat('EEE, MMM d, y').format(local)}',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.person_outline, size: 12, color: muted),
          const SizedBox(width: 2),
          Text(text, style: theme.textTheme.labelSmall?.copyWith(color: muted)),
        ],
      ),
    );
  }
}

/// A compact pill that opens a checklist, e.g. "Priority · 2 ▾".
class _FilterMenu extends StatelessWidget {
  const _FilterMenu({
    required this.label,
    required this.options,
    required this.selected,
    required this.optionLabel,
    required this.optionIcon,
    required this.onToggle,
  });

  final String label;
  final List<String> options;
  final Set<String> selected;
  final String Function(String option) optionLabel;
  final Widget? Function(String option) optionIcon;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final active = selected.isNotEmpty;
    final fg = active ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;

    return MenuAnchor(
      menuChildren: [
        for (final option in options)
          MenuItemButton(
            // Stay open so several can be ticked in one go.
            closeOnActivate: false,
            leadingIcon: Icon(
              selected.contains(option) ? Icons.check_box : Icons.check_box_outline_blank,
              size: 18,
              color: selected.contains(option) ? scheme.primary : scheme.onSurfaceVariant,
            ),
            onPressed: () => onToggle(option),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (optionIcon(option) case final icon?) ...[icon, const SizedBox(width: 6)],
                Text(optionLabel(option)),
              ],
            ),
          ),
      ],
      builder: (context, menu, _) => Material(
        color: active ? scheme.secondaryContainer : Colors.transparent,
        shape: StadiumBorder(side: BorderSide(color: active ? Colors.transparent : scheme.outlineVariant)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: options.isEmpty ? null : () => menu.isOpen ? menu.close() : menu.open(),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 3, 4, 3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  active ? '$label · ${selected.length}' : label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: fg,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
                Icon(Icons.arrow_drop_down, size: 18, color: fg),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
