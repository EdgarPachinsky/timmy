import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/claude_cli.dart';
import '../../core/format.dart';
import '../../core/jira_client.dart';
import '../../core/planner.dart';
import '../../models/jira.dart';
import '../../models/models.dart';
import '../../state/claude_controller.dart';
import '../../state/jira_controller.dart';
import '../../state/tracker_controller.dart';
import '../../state/workspace_session.dart';
import '../../widgets/common.dart';
import '../jira/jira_task_list.dart';
import '../jira/jira_tasks_page.dart';
import '../settings/claude_connector_page.dart';
import '../settings/jira_connector_page.dart';
import '../tracker/tracker_logic.dart';
import 'standup_dialog.dart';

/// Today's plan from your Jira tasks: what to work on, how long, and
/// heads-ups; optionally ordered by Claude, plus a one-click standup.
class PlanPage extends StatefulWidget {
  const PlanPage({super.key, required this.onStart});

  /// Start tracking [item] (fills the tracker and switches to it).
  final ValueChanged<PlanItem> onStart;

  @override
  State<PlanPage> createState() => _PlanPageState();
}

class _PlanPageState extends State<PlanPage> {
  List<JiraIssue>? _issues;
  bool _loading = false;
  String? _error;

  /// Claude's plan, for the day it was made.
  List<ClaudePlanStep>? _aiSteps;
  String _aiNote = '';
  DateTime? _aiDay;
  bool _aiLoading = false;

  bool _showLater = false;
  bool _showWaiting = false;

  Future<void> _load() async {
    final jira = context.read<JiraController>();
    if (!jira.isConnected || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final issues = await jira.findTasks('', refresh: true);
      if (mounted) setState(() => _issues = issues);
    } on JiraException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _askClaude(DayPlan plan) async {
    final claude = context.read<ClaudeController>();
    final messenger = ScaffoldMessenger.of(context);
    final now = DateTime.now();
    setState(() => _aiLoading = true);
    try {
      final answer = await claude.ask(
        kind: 'plan',
        instruction: claudePlanInstruction,
        input: _prettyJson(claudePlanInput(plan, now)),
        schema: claudePlanSchema,
      );
      final structured = answer.structured;
      if (structured == null) throw const ClaudeException('Claude didn\'t return a plan.');
      if (!mounted) return;
      setState(() {
        _aiSteps = parseClaudePlan(structured);
        _aiNote = structured['note'] as String? ?? '';
        _aiDay = dateOnly(now);
      });
    } on ClaudeException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text("Claude couldn't plan: ${e.message}")));
    } finally {
      if (mounted) setState(() => _aiLoading = false);
    }
  }

  void _openIssue(PlanItem item) {
    final jira = context.read<JiraController>();
    showJiraIssueDetails(context, jira, item.issue, onMoved: _load);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final jira = context.watch<JiraController>();
    final claude = context.watch<ClaudeController>();
    final session = context.watch<WorkspaceSession>();
    final tracker = context.watch<TrackerController>();

    if (!jira.isConnected) {
      return _NotConnected(onConnect: () => openJiraConnector(context));
    }
    if (_issues == null && !_loading && _error == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
    final issues = _issues;
    if (issues == null) {
      return _error != null
          ? ErrorState(message: _error!, onRetry: _load)
          : const Center(child: CircularProgressIndicator());
    }

    final now = DateTime.now();
    final entries = <TimeEntry>[
      ...?session.entries.data,
      for (final p in tracker.local) p.asTimeEntry(),
    ];
    var plan = buildDayPlan(
      issues: issues,
      entries: entries,
      now: now,
      myAccountId: jira.accountId,
      runningMinutes: tracker.isActive ? roundToMinutes(tracker.elapsed) : 0,
      localEntryCount: tracker.local.length,
    );
    final steps = _aiSteps;
    if (steps != null && _aiDay == dateOnly(now)) plan = applyClaudePlan(plan, steps, _aiNote);

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Today · ${DateFormat('EEE, MMM d').format(now)}',
                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            if (_loading)
              const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            IconButton(
              tooltip: 'Reload tasks',
              iconSize: 18,
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        _CapacityCard(plan: plan),
        for (final nudge in plan.nudges) ...[
          const SizedBox(height: 6),
          _NudgeRow(nudge: nudge),
        ],
        const SizedBox(height: 10),
        _ClaudeBar(
          claude: claude,
          plan: plan,
          loading: _aiLoading,
          onAsk: () => _askClaude(plan),
          onReset: () => setState(() => _aiSteps = null),
          onConnect: () => openClaudeConnector(context),
        ),
        if (plan.aiNote != null) ...[
          const SizedBox(height: 8),
          InlineNotice(icon: Icons.auto_awesome, message: plan.aiNote!),
        ],
        const SizedBox(height: 12),
        _SectionHeader(
          title: 'Plan for today',
          detail: plan.today.isEmpty
              ? null
              : '${plan.today.length} ${plan.today.length == 1 ? 'task' : 'tasks'} · '
                  '${formatMinutes(plan.plannedMinutes)}',
        ),
        const SizedBox(height: 6),
        if (plan.today.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                issues.isEmpty
                    ? 'No open Jira tasks are assigned to you.'
                    : plan.trackedMinutes >= plan.capacityMinutes
                        ? 'Your day is full. Anything else is under Later.'
                        : 'Nothing to plan right now.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          )
        else
          _PlanCard(
            items: plan.today,
            numbered: true,
            onStart: widget.onStart,
            onOpen: _openIssue,
            canStart: !tracker.isActive,
          ),
        if (plan.later.isNotEmpty) ...[
          const SizedBox(height: 10),
          _Collapsible(
            title: 'Later',
            count: plan.later.length,
            open: _showLater,
            onToggle: () => setState(() => _showLater = !_showLater),
            child: _PlanCard(
              items: plan.later,
              onStart: widget.onStart,
              onOpen: _openIssue,
              canStart: !tracker.isActive,
            ),
          ),
        ],
        if (plan.waiting.isNotEmpty) ...[
          const SizedBox(height: 10),
          _Collapsible(
            title: 'Waiting on review / test',
            count: plan.waiting.length,
            open: _showWaiting,
            onToggle: () => setState(() => _showWaiting = !_showWaiting),
            child: _PlanCard(
              items: plan.waiting,
              onStart: widget.onStart,
              onOpen: _openIssue,
              canStart: !tracker.isActive,
            ),
          ),
        ],
        const SizedBox(height: 14),
        FilledButton.tonalIcon(
          onPressed: () => showStandupDialog(
            context,
            claude: claude,
            data: standupData(entries, plan, now),
            now: now,
          ),
          icon: const Icon(Icons.record_voice_over_outlined, size: 18),
          label: const Text('Write standup'),
        ),
      ],
    );
  }
}

/// Indented so the input stays readable if someone inspects it.
final _prettyJson = const JsonEncoder.withIndent('  ').convert;

class _NotConnected extends StatelessWidget {
  const _NotConnected({required this.onConnect});

  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.event_note_outlined, size: 36, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 10),
            Text(
              'Plan your day from your Jira tasks',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'Connect Jira and Timmy ranks your tasks, fits them into an 8h day and flags what needs attention.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 14),
            FilledButton(onPressed: onConnect, child: const Text('Connect Jira')),
          ],
        ),
      ),
    );
  }
}

/// Tracked + planned against the 8h day.
class _CapacityCard extends StatelessWidget {
  const _CapacityCard({required this.plan});

  final DayPlan plan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final capacity = plan.capacityMinutes;
    final tracked = plan.trackedMinutes;
    final planned = plan.plannedMinutes;
    final over = tracked > capacity;
    final total = over ? tracked : capacity;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  formatMinutes(tracked + planned),
                  style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800, height: 1.1),
                ),
                Text(' of ${formatMinutes(capacity)}', style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                const Spacer(),
                Text(
                  over ? '+${formatMinutes(tracked - capacity)} overtime' : '${formatMinutes(plan.freeMinutes)} free',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: over ? scheme.tertiary : muted,
                    fontWeight: over ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                height: 8,
                child: Row(
                  children: [
                    if (tracked > 0)
                      Expanded(
                        flex: (over ? capacity : tracked),
                        child: Container(color: scheme.primary),
                      ),
                    if (over)
                      Expanded(flex: tracked - capacity, child: Container(color: scheme.tertiary)),
                    if (!over && planned > 0)
                      Expanded(flex: planned, child: Container(color: scheme.primary.withValues(alpha: 0.4))),
                    if (!over && total - tracked - planned > 0)
                      Expanded(
                        flex: total - tracked - planned,
                        child: Container(color: scheme.surfaceContainerHighest),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                _Legend(color: scheme.primary, label: '${formatMinutes(tracked)} tracked'),
                const SizedBox(width: 12),
                _Legend(color: scheme.primary.withValues(alpha: 0.4), label: '${formatMinutes(planned)} planned'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 4),
        Text(label, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }
}

class _NudgeRow extends StatelessWidget {
  const _NudgeRow({required this.nudge});

  final PlanNudge nudge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (icon, color) = switch (nudge.kind) {
      NudgeKind.overtime => (Icons.more_time, scheme.tertiary),
      NudgeKind.overdue => (Icons.event_busy_outlined, scheme.error),
      NudgeKind.wip => (Icons.layers_outlined, scheme.primary),
      NudgeKind.stale => (Icons.hourglass_bottom, scheme.onSurfaceVariant),
      NudgeKind.overrun => (Icons.speed, scheme.tertiary),
      NudgeKind.local => (Icons.laptop_mac_outlined, scheme.onSurfaceVariant),
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(nudge.text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}

/// "Ask Claude to plan" (or a link to connect Claude).
class _ClaudeBar extends StatelessWidget {
  const _ClaudeBar({
    required this.claude,
    required this.plan,
    required this.loading,
    required this.onAsk,
    required this.onReset,
    required this.onConnect,
  });

  final ClaudeController claude;
  final DayPlan plan;
  final bool loading;
  final VoidCallback onAsk;
  final VoidCallback onReset;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!claude.isConnected) {
      return InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onConnect,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Icon(Icons.auto_awesome, size: 15, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Connect Claude for a smarter plan and standups',
                  style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary),
                ),
              ),
              Icon(Icons.chevron_right, size: 16, color: theme.colorScheme.primary),
            ],
          ),
        ),
      );
    }
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: loading ? null : onAsk,
            icon: loading
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.auto_awesome, size: 16),
            label: Text(loading
                ? 'Claude is planning…'
                : plan.fromClaude
                    ? 'Re-plan with Claude'
                    : 'Ask Claude to plan'),
          ),
        ),
        if (plan.fromClaude) ...[
          const SizedBox(width: 6),
          TextButton(onPressed: loading ? null : onReset, child: const Text('Simple plan')),
        ],
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.detail});

  final String title;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(title, style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
        ),
        if (detail != null)
          Text(detail!, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }
}

class _Collapsible extends StatelessWidget {
  const _Collapsible({
    required this.title,
    required this.count,
    required this.open,
    required this.onToggle,
    required this.child,
  });

  final String title;
  final int count;
  final bool open;
  final VoidCallback onToggle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                AnimatedRotation(
                  turns: open ? 0 : -0.25,
                  duration: const Duration(milliseconds: 150),
                  child: Icon(Icons.expand_more, size: 18, color: muted),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(title, style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
                ),
                Text('$count', style: theme.textTheme.labelSmall?.copyWith(color: muted)),
              ],
            ),
          ),
        ),
        if (open) ...[const SizedBox(height: 4), child],
      ],
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.items,
    required this.onStart,
    required this.onOpen,
    required this.canStart,
    this.numbered = false,
  });

  final List<PlanItem> items;
  final ValueChanged<PlanItem> onStart;
  final ValueChanged<PlanItem> onOpen;
  final bool canStart;
  final bool numbered;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            _PlanRow(
              item: items[i],
              rank: numbered ? i + 1 : null,
              canStart: canStart,
              onStart: () => onStart(items[i]),
              onOpen: () => onOpen(items[i]),
            ),
          ],
        ],
      ),
    );
  }
}

/// One task: rank, key, priority, status, title, why, and time + Start.
class _PlanRow extends StatelessWidget {
  const _PlanRow({
    required this.item,
    required this.rank,
    required this.canStart,
    required this.onStart,
    required this.onOpen,
  });

  final PlanItem item;
  final int? rank;
  final bool canStart;
  final VoidCallback onStart;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final issue = item.issue;
    final meta = [
      if (issue.status.isNotEmpty) issue.status,
      ...item.reasons.where((r) => r != 'In progress' && !r.endsWith('priority')),
      if (item.loggedMinutes > 0) '${formatMinutes(item.loggedMinutes)} logged',
    ].join(' · ');

    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (rank != null)
              Container(
                width: 20,
                height: 20,
                margin: const EdgeInsets.only(top: 1, right: 8),
                alignment: Alignment.center,
                decoration: BoxDecoration(color: scheme.primaryContainer, shape: BoxShape.circle),
                child: Text(
                  '$rank',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onPrimaryContainer,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      JiraTypeIcon(type: issue.issueType),
                      const SizedBox(width: 4),
                      Text(
                        issue.key,
                        style: theme.textTheme.labelSmall?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700),
                      ),
                      if (issue.priority.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        JiraPriority(name: issue.priority),
                      ],
                      const SizedBox(width: 6),
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: jiraStatusColor(issue.statusCategory, scheme),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    issue.summary.isEmpty ? '(no title)' : issue.summary,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, height: 1.25),
                  ),
                  if (item.aiReason != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 2, right: 4),
                            child: Icon(Icons.auto_awesome, size: 11, color: scheme.primary),
                          ),
                          Expanded(
                            child: Text(
                              item.aiReason!,
                              style: theme.textTheme.labelSmall?.copyWith(color: scheme.primary),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (meta.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        meta,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(color: muted),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Text(
                    formatMinutes(item.suggestedMinutes),
                    style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: canStart ? 'Start ${issue.key}' : 'Finish the running timer first',
                  color: scheme.primary,
                  iconSize: 22,
                  onPressed: canStart ? onStart : null,
                  icon: const Icon(Icons.play_circle_outline),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
