import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/claude_cli.dart';
import '../../core/format.dart';
import '../../core/jira_client.dart';
import '../../core/planner.dart';
import '../../core/trello_client.dart';
import '../../models/jira.dart';
import '../../models/models.dart';
import '../../models/trello.dart';
import '../../state/claude_controller.dart';
import '../../state/jira_controller.dart';
import '../../state/tracker_controller.dart';
import '../../state/trello_controller.dart';
import '../../state/workspace_session.dart';
import '../../widgets/common.dart';
import '../entries/entry_editor.dart';
import '../jira/jira_task_list.dart';
import '../jira/jira_tasks_page.dart';
import '../settings/claude_connector_page.dart';
import '../settings/jira_connector_page.dart';
import '../settings/trello_connector_page.dart';
import '../trello/trello_cards_page.dart';
import '../tracker/tracker_logic.dart';
import 'standup_dialog.dart';
import 'step_progress.dart';

/// Today's plan from your Jira tasks, Trello cards and the work in your recent
/// entries: what to work on, how long, and heads-ups; optionally ordered by
/// Claude, plus a one-click standup.
class PlanPage extends StatefulWidget {
  const PlanPage({super.key, required this.onStart, this.onPlan, this.onStandup});

  /// Start tracking [item] (fills the tracker and switches to it).
  final ValueChanged<PlanItem> onStart;

  /// Today's plan whenever it changes.
  final ValueChanged<List<PlanItem>?>? onPlan;

  /// A standup was written (by Claude, or copied).
  final ValueChanged<String>? onStandup;

  @override
  State<PlanPage> createState() => _PlanPageState();
}

class _PlanPageState extends State<PlanPage> {
  /// Null until loaded (or while that source isn't connected).
  List<JiraIssue>? _issues;
  List<TrelloCard>? _cards;
  bool _loading = false;

  /// Per source, why the last load failed.
  String? _jiraError;
  String? _trelloError;

  /// Which sources the loaded data is for, to reload when that changes.
  String? _loadedFor;

  /// Jira issues your recent entries name that aren't on your open list
  /// (often done by now), with their real status; and which keys they're for.
  List<JiraIssue> _related = const [];
  String? _relatedFor;
  bool _relatedLoading = false;

  /// Looks up the Jira keys in your recent entries that aren't open tasks,
  /// so done tickets don't come back as "recent work".
  Future<void> _loadRelated(Set<String> keys) async {
    final jira = context.read<JiraController>();
    if (!jira.isConnected) return;
    _relatedLoading = true;
    try {
      final issues = keys.isEmpty ? const <JiraIssue>[] : await jira.issuesByKeys(keys);
      if (mounted) setState(() => _related = issues);
    } on JiraException {
      // Without statuses, those entries are still kept out of recent work.
    } finally {
      _relatedLoading = false;
    }
  }

  /// Keys named in recent entries that aren't among the open [issues].
  static Set<String> _keysToLookUp(List<TimeEntry> entries, List<JiraIssue> issues, DateTime now) {
    final open = {for (final i in issues) i.key.toUpperCase()};
    return {
      for (final k in recentJiraKeys(entries, now))
        if (!open.contains(k.toUpperCase())) k.toUpperCase(),
    };
  }

  static String _signature(Set<String> keys) => (keys.toList()..sort()).join(',');

  /// Claude's plan, for the day it was made.
  List<ClaudePlanStep>? _aiSteps;
  String _aiNote = '';
  DateTime? _aiDay;
  bool _aiLoading = false;

  /// The step shown under the Claude button while planning: what's being
  /// done, whether it's finished, and whether it went fine.
  ProgressStep? _progress;

  bool _showLater = false;
  bool _showWaiting = false;

  /// What [PlanPage.onPlan] was last told, to report only changes.
  String? _reportedPlan;

  void _reportPlan(List<PlanItem>? items) {
    final signature = items == null
        ? 'none'
        : [for (final i in items) '${i.task.ref}:${i.task.title}:${i.suggestedMinutes}'].join('|');
    if (signature == _reportedPlan || widget.onPlan == null) return;
    _reportedPlan = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onPlan!(items);
    });
  }

  static String _sources(JiraController jira, TrelloController trello) =>
      '${jira.isConnected}/${trello.isConnected}';

  /// Loads the connected sources side by side; one failing doesn't stop the
  /// other, and the plan still has your recent work.
  Future<void> _load() async {
    final jira = context.read<JiraController>();
    final trello = context.read<TrelloController>();
    if (_loading) return;
    _loadedFor = _sources(jira, trello);
    setState(() {
      _loading = true;
      _jiraError = null;
      _trelloError = null;
      if (!jira.isConnected) {
        _issues = null;
        _related = const [];
        _relatedFor = null;
      }
      if (!trello.isConnected) _cards = null;
    });
    await Future.wait([
      if (jira.isConnected)
        () async {
          try {
            final issues = await jira.findTasks('', refresh: true);
            if (mounted) setState(() => _issues = issues);
          } on JiraException catch (e) {
            if (mounted) setState(() => _jiraError = e.message);
          }
        }(),
      if (trello.isConnected)
        () async {
          try {
            final cards = await trello.findCards('', refresh: true);
            if (mounted) setState(() => _cards = cards);
          } on TrelloException catch (e) {
            if (mounted) setState(() => _trelloError = e.message);
          }
        }(),
    ]);
    if (mounted) setState(() => _loading = false);
  }

  /// Fresh data, step by step: Jira tickets, Trello cards, then your entries
  /// (and the status of done tickets they name). Each step shows through
  /// [step]; a source that fails is marked and the rest carries on.
  Future<void> _gather(StepRunner step) async {
    final jira = context.read<JiraController>();
    final trello = context.read<TrelloController>();
    final session = context.read<WorkspaceSession>();
    if (jira.isConnected) {
      await step('Gathering Jira tickets', () async {
        try {
          final issues = await jira.findTasks('', refresh: true);
          if (mounted) {
            setState(() {
              _issues = issues;
              _jiraError = null;
            });
          }
          return true;
        } on JiraException catch (e) {
          if (mounted) setState(() => _jiraError = e.message);
          return false;
        }
      });
    }
    if (trello.isConnected) {
      await step('Getting tasks from Trello', () async {
        try {
          final cards = await trello.findCards('', refresh: true);
          if (mounted) {
            setState(() {
              _cards = cards;
              _trelloError = null;
            });
          }
          return true;
        } on TrelloException catch (e) {
          if (mounted) setState(() => _trelloError = e.message);
          return false;
        }
      });
    }
    await step('Reading your recent entries', () async {
      await session.loadEntries();
      // Tickets named there that aren't open (e.g. done): their status.
      final issues = _issues;
      if (jira.isConnected && issues != null && session.entries.data != null) {
        final keys = _keysToLookUp(session.entries.data!, issues, DateTime.now());
        _relatedFor = _signature(keys);
        await _loadRelated(keys);
      }
      return session.entries.error == null;
    });
  }

  /// Fresh data, then the standup's material from it (with Claude's plan for
  /// today, if there is one).
  Future<StandupData?> _prepareStandup(StepRunner step) async {
    await _gather(step);
    if (!mounted) return null;
    final now = DateTime.now();
    final session = context.read<WorkspaceSession>();
    final tracker = context.read<TrackerController>();
    var plan = _simplePlan(
      jira: context.read<JiraController>(),
      trello: context.read<TrelloController>(),
      session: session,
      tracker: tracker,
      now: now,
    );
    final steps = _aiSteps;
    if (steps != null && _aiDay == dateOnly(now)) plan = applyClaudePlan(plan, steps, _aiNote);
    final entries = <TimeEntry>[
      ...?session.entries.data,
      for (final p in tracker.local) p.asTimeEntry(),
    ];
    return standupData(entries, plan, now);
  }

  /// Plans with Claude in visible steps: fresh Jira tickets, Trello cards
  /// and entries first, then Claude. Each step shows a spinner, then a check,
  /// then gives way to the next.
  Future<void> _askClaude() async {
    final claude = context.read<ClaudeController>();
    final jira = context.read<JiraController>();
    final trello = context.read<TrelloController>();
    final session = context.read<WorkspaceSession>();
    final tracker = context.read<TrackerController>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _aiLoading = true);

    final step = stepRunner(mounted: () => mounted, show: (s) => setState(() => _progress = s));

    try {
      await _gather(step);
      if (!mounted) return;

      await step('Claude is planning your day', () async {
        final now = DateTime.now();
        final plan = _simplePlan(jira: jira, trello: trello, session: session, tracker: tracker, now: now);
        final answer = await claude.ask(
          kind: 'plan',
          instruction: claudePlanInstruction,
          input: _prettyJson(claudePlanInput(plan, now)),
          schema: claudePlanSchema,
        );
        final structured = answer.structured;
        if (structured == null) throw const ClaudeException('Claude didn\'t return a plan.');
        if (mounted) {
          setState(() {
            _aiSteps = parseClaudePlan(structured);
            _aiNote = structured['note'] as String? ?? '';
            _aiDay = dateOnly(now);
          });
        }
        return true;
      });
    } on ClaudeException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text("Claude couldn't plan: ${e.message}")));
    } finally {
      if (mounted) {
        setState(() {
          _aiLoading = false;
          _progress = null;
        });
      }
    }
  }

  /// The rule-based plan from what's loaded (before Claude reorders it).
  DayPlan _simplePlan({
    required JiraController jira,
    required TrelloController trello,
    required WorkspaceSession session,
    required TrackerController tracker,
    required DateTime now,
  }) {
    final entries = <TimeEntry>[
      ...?session.entries.data,
      for (final p in tracker.local) p.asTimeEntry(),
    ];
    return buildDayPlan(
      issues: jira.isConnected ? _issues ?? const [] : const [],
      cards: trello.isConnected ? _cards ?? const [] : const [],
      relatedIssues: jira.isConnected ? _related : const [],
      jiraConnected: jira.isConnected,
      entries: entries,
      now: now,
      myAccountId: jira.accountId,
      trelloMemberId: trello.member?.id,
      runningMinutes: tracker.isActive ? roundToMinutes(tracker.elapsed) : 0,
      localEntryCount: tracker.local.length,
    );
  }

  /// Logs [item]'s planned time as a real entry: "Add time" filled with the
  /// task (titled as the pickers would), its planned time, today and the
  /// project it was last tracked on; it goes to Time-Wise or this Mac.
  Future<void> _logTime(PlanItem item) {
    final picked = _entryTextFor(item.task);
    return addTimeManually(
      context,
      draft: EntryDraft(
        projectId: item.lastProjectId,
        title: picked.title.length > 500 ? picked.title.substring(0, 500) : picked.title,
        description: picked.description,
        minutes: item.suggestedMinutes,
        date: DateTime.now(),
      ),
    );
  }

  /// What an entry for [task] is called: the same title (and description)
  /// the task pickers would give it.
  ({String title, String? description}) _entryTextFor(PlanTask task) {
    final ({String title, String? description}) picked = task.jira != null
        ? context.read<JiraController>().taskFor(task.jira!)
        : task.trello != null
            ? context.read<TrelloController>().taskFor(task.trello!)
            : (title: task.title, description: null);
    final title = picked.title.trim();
    return (title: title.length > 500 ? title.substring(0, 500) : title, description: picked.description);
  }

  /// A task can be logged until it has time today (no duplicates).
  static bool _canLog(PlanItem item) => item.loggedTodayMinutes == 0;

  bool _bulkLogging = false;

  /// Logs every task planned for today that has no time yet straight to
  /// Time-Wise, each on the project it was last tracked on (else the
  /// tracker's), with Undo.
  Future<void> _logAll(List<PlanItem> items) async {
    if (_bulkLogging) return;
    final session = context.read<WorkspaceSession>();
    final tracker = context.read<TrackerController>();
    final messenger = ScaffoldMessenger.of(context);
    final projects = session.trackableProjects;
    bool trackable(int? id) => id != null && projects.any((p) => p.id == id);

    final today = dateKey(DateTime.now());
    final payloads = <Map<String, dynamic>>[];
    final skipped = <String>[];
    for (final item in items.where(_canLog)) {
      final projectId = trackable(item.lastProjectId)
          ? item.lastProjectId
          : trackable(tracker.projectId)
              ? tracker.projectId
              : null;
      if (projectId == null || item.suggestedMinutes < 1) {
        skipped.add(item.task.shortName);
        continue;
      }
      final text = _entryTextFor(item.task);
      final description = text.description?.trim() ?? '';
      payloads.add({
        'projectId': projectId,
        'taskTitle': text.title,
        'description': description.isEmpty ? null : description,
        'hours': item.suggestedMinutes ~/ 60,
        'minutes': item.suggestedMinutes % 60,
        'date': today,
        'billable': tracker.billable,
        'tagIds': <int>[],
      });
    }
    if (payloads.isEmpty) {
      messenger.showSnackBar(SnackBar(
        content: Text(skipped.isEmpty
            ? 'Nothing to log: every planned task already has time today.'
            : 'Pick a project in the tracker first, then try again.'),
      ));
      return;
    }

    setState(() => _bulkLogging = true);
    try {
      final result = await session.createEntries(payloads);
      final created = result.created;
      final minutes = created.fold<int>(0, (sum, e) => sum + e.totalMinutes);
      final parts = [
        if (created.isNotEmpty)
          'Logged ${created.length} ${created.length == 1 ? 'task' : 'tasks'} '
              '(${formatMinutes(minutes)}) to Time-Wise.',
        if (result.error != null) "Couldn't log the rest: ${result.error}",
        if (skipped.isNotEmpty) 'Skipped ${skipped.join(', ')} (no project).',
      ];
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
        content: Text(parts.join(' ')),
        persist: false,
        duration: const Duration(seconds: 6),
        action: created.isEmpty
            ? null
            : SnackBarAction(
                label: 'Undo',
                onPressed: () async {
                  try {
                    await session.deleteEntries([for (final e in created) e.id]);
                  } on ApiException catch (e) {
                    messenger.showSnackBar(SnackBar(content: Text("Couldn't undo: ${e.message}")));
                  }
                },
              ),
      ));
    } finally {
      if (mounted) setState(() => _bulkLogging = false);
    }
  }

  /// Details of the Jira issue or Trello card; recent work has none.
  void _openTask(PlanItem item) {
    final task = item.task;
    if (task.jira != null) {
      showJiraIssueDetails(context, context.read<JiraController>(), task.jira!, onMoved: _load);
    } else if (task.trello != null) {
      showTrelloCardDetails(context, task.trello!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final jira = context.watch<JiraController>();
    final trello = context.watch<TrelloController>();
    final claude = context.watch<ClaudeController>();
    final session = context.watch<WorkspaceSession>();
    final tracker = context.watch<TrackerController>();

    // First visit, or Jira / Trello connected or disconnected since.
    if (!_loading && _loadedFor != _sources(jira, trello)) {
      _loadedFor = _sources(jira, trello);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
    final waitingFirstLoad = (jira.isConnected && _issues == null && _jiraError == null) ||
        (trello.isConnected && _cards == null && _trelloError == null);
    if (waitingFirstLoad || (session.entries.data == null && session.entries.loading)) {
      return const Center(child: CircularProgressIndicator());
    }

    final now = DateTime.now();
    final entries = <TimeEntry>[
      ...?session.entries.data,
      for (final p in tracker.local) p.asTimeEntry(),
    ];
    // Jira keys in recent entries that aren't open tasks: look up their status.
    final issues = _issues;
    if (jira.isConnected && issues != null && session.entries.data != null && !_relatedLoading) {
      final keys = _keysToLookUp(entries, issues, now);
      if (_signature(keys) != _relatedFor) {
        _relatedFor = _signature(keys);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _loadRelated(keys);
        });
      }
    }
    var plan = _simplePlan(jira: jira, trello: trello, session: session, tracker: tracker, now: now);
    final steps = _aiSteps;
    if (steps != null && _aiDay == dateOnly(now)) plan = applyClaudePlan(plan, steps, _aiNote);
    _reportPlan(plan.today);

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
        if (!jira.isConnected && !trello.isConnected) ...[
          _ConnectHint(
            jira: jira.isConnected,
            trello: trello.isConnected,
            onConnectJira: () => openJiraConnector(context),
            onConnectTrello: () => openTrelloConnector(context),
          ),
          const SizedBox(height: 8),
        ],
        for (final (name, error) in [('Jira', _jiraError), ('Trello', _trelloError)])
          if (error != null) ...[
            InlineNotice(
              icon: Icons.error_outline,
              isError: true,
              message: "Couldn't load $name: $error",
              actions: [TextButton(onPressed: _loading ? null : _load, child: const Text('Retry'))],
            ),
            const SizedBox(height: 8),
          ],
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
          onAsk: _askClaude,
          onReset: () => setState(() => _aiSteps = null),
          onConnect: () => openClaudeConnector(context),
        ),
        StepProgress(step: _progress),
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
                plan.all.isEmpty
                    ? 'Nothing to plan yet: no open Jira tasks or Trello cards on you, and no recent work in your entries.'
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
            onOpen: _openTask,
            onLog: _logTime,
            canStart: !tracker.isActive,
          ),
        if (plan.today.isNotEmpty)
          Align(
            alignment: Alignment.centerRight,
            child: Builder(builder: (context) {
              final loggable = plan.today.where(_canLog).toList();
              final minutes = loggable.fold<int>(0, (sum, i) => sum + i.suggestedMinutes);
              return TextButton.icon(
                onPressed: loggable.isEmpty || _bulkLogging ? null : () => _logAll(plan.today),
                icon: _bulkLogging
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.cloud_upload_outlined, size: 16),
                label: Text(loggable.isEmpty
                    ? 'All planned tasks have time today'
                    : 'Log all to Time-Wise (${formatMinutes(minutes)})'),
              );
            }),
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
              onOpen: _openTask,
            onLog: _logTime,
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
              onOpen: _openTask,
            onLog: _logTime,
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
            onWritten: widget.onStandup,
            prepare: _prepareStandup,
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

/// Neither Jira nor Trello is connected: the plan comes from recent work in
/// your entries only; connecting either adds your tasks to it.
class _ConnectHint extends StatelessWidget {
  const _ConnectHint({
    required this.jira,
    required this.trello,
    required this.onConnectJira,
    required this.onConnectTrello,
  });

  final bool jira;
  final bool trello;
  final VoidCallback onConnectJira;
  final VoidCallback onConnectTrello;

  @override
  Widget build(BuildContext context) {
    return InlineNotice(
      icon: Icons.link,
      message: 'Planning from your recent entries. Connect Jira or Trello to plan from your tasks too.',
      actions: [
        if (!jira) TextButton(onPressed: onConnectJira, child: const Text('Connect Jira')),
        if (!trello) TextButton(onPressed: onConnectTrello, child: const Text('Connect Trello')),
      ],
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
                ? 'Planning with Claude…'
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
    required this.onLog,
    required this.canStart,
    this.numbered = false,
  });

  final List<PlanItem> items;
  final ValueChanged<PlanItem> onStart;
  final ValueChanged<PlanItem> onOpen;

  /// Log the planned time as an entry.
  final ValueChanged<PlanItem> onLog;
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
              onLog: () => onLog(items[i]),
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
    required this.onLog,
  });

  final PlanItem item;
  final int? rank;
  final bool canStart;
  final VoidCallback onStart;
  final VoidCallback onOpen;
  final VoidCallback onLog;

  static const _compact = BoxConstraints.tightFor(width: 32, height: 32);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final task = item.task;
    final meta = [
      if (task.status.isNotEmpty) task.status,
      ...item.reasons.where((r) => r != 'In progress' && !r.endsWith('priority')),
      if (item.loggedMinutes > 0) '${formatMinutes(item.loggedMinutes)} logged',
    ].join(' · ');

    return InkWell(
      // Recent work has no Jira issue or Trello card to open.
      onTap: task.source == TaskSource.entries ? null : onOpen,
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
                      switch (task.source) {
                        TaskSource.jira => JiraTypeIcon(type: task.type),
                        TaskSource.trello =>
                          Icon(Icons.view_kanban_outlined, size: 14, color: scheme.primary),
                        TaskSource.entries => Icon(Icons.history, size: 14, color: muted),
                      },
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          switch (task.source) {
                            TaskSource.jira => task.label,
                            TaskSource.trello =>
                              [task.label, task.place].where((s) => s.isNotEmpty).join(' · '),
                            TaskSource.entries => 'Recent work',
                          },
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: task.source == TaskSource.entries ? muted : scheme.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (task.priority.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        JiraPriority(name: task.priority),
                      ],
                      const SizedBox(width: 6),
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: jiraStatusColor(task.statusCategory, scheme),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    task.title.isEmpty ? '(no title)' : task.title,
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
                  // Recent work: what you last wrote about it.
                  if (task.source == TaskSource.entries && task.description.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        'Last note: ${task.description}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(color: muted, fontStyle: FontStyle.italic),
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
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Log the planned time without running the timer.
                    IconButton(
                      tooltip: item.loggedTodayMinutes > 0
                          ? 'Already has time today'
                          : 'Log ${formatMinutes(item.suggestedMinutes)} as an entry',
                      color: muted,
                      iconSize: 20,
                      constraints: _compact,
                      padding: EdgeInsets.zero,
                      // Once it has time today, logging again would duplicate it.
                      onPressed: item.loggedTodayMinutes > 0 ? null : onLog,
                      icon: const Icon(Icons.more_time),
                    ),
                    IconButton(
                      tooltip: canStart ? 'Start ${task.shortName}' : 'Finish the running timer first',
                      color: scheme.primary,
                      iconSize: 22,
                      onPressed: canStart ? onStart : null,
                      icon: const Icon(Icons.play_circle_outline),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
