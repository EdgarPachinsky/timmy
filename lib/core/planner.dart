import 'dart:math' as math;

import 'package:intl/intl.dart';

import '../models/jira.dart';
import '../models/models.dart';
import '../models/trello.dart';
import 'format.dart';
import 'overtime.dart';

/// A day's worth of planned work (the same 8h as the overtime rule).
const dayCapacityMinutes = regularDayMinutes;

/// Where a task in the plan comes from.
enum TaskSource {
  jira,
  trello,

  /// Work you've been tracking that isn't a Jira or Trello task, found from
  /// your recent time entries (their titles and descriptions).
  entries,
}

/// A task to plan, whatever its source: a Jira issue, a Trello card, or
/// recent work from your time entries.
class PlanTask {
  const PlanTask({
    required this.source,
    required this.ref,
    required this.title,
    this.label = '',
    this.description = '',
    this.status = '',
    this.statusCategory = 'new',
    this.type = '',
    this.priority = '',
    this.place = '',
    this.due,
    this.assignedAt,
    this.originalEstimateMinutes,
    this.remainingEstimateMinutes,
    this.timeSpentMinutes,
    this.lastWorked,
    this.daysWorked = 0,
    this.jira,
    this.trello,
  });

  final TaskSource source;

  /// Stable id, also what Claude answers with: the Jira key, `TRELLO-<id>`
  /// or `WORK-<hash of the title>`. Upper case.
  final String ref;

  /// Short tag before the title: the Jira key, the Trello card number
  /// ("#42"), or empty for recent work.
  final String label;
  final String title;

  /// Plain text: the Jira or Trello description, or the latest note from
  /// your entries for recent work.
  final String description;

  /// Jira status or Trello list name; empty for recent work.
  final String status;

  /// `new`, `indeterminate` (in progress) or `done`, like Jira's.
  final String statusCategory;

  /// Jira issue type; empty otherwise.
  final String type;

  /// "Highest" … "Lowest" (Trello: from labels like "urgent" or "high").
  final String priority;

  /// Jira project or Trello board name.
  final String place;
  final DateTime? due;

  /// When it became yours (Jira only).
  final DateTime? assignedAt;
  final int? originalEstimateMinutes;
  final int? remainingEstimateMinutes;
  final int? timeSpentMinutes;

  /// Recent work: the last day it was tracked, and on how many days lately.
  final DateTime? lastWorked;
  final int daysWorked;

  final JiraIssue? jira;
  final TrelloCard? trello;

  int get priorityRank => jiraPriorityRank(priority);

  /// "CDEV-12 Fix login", "#42 Fix login" or "Fix login".
  String get displayName => label.isEmpty ? title : '$label $title';

  /// For messages: the label, else the title shortened.
  String get shortName => label.isNotEmpty
      ? label
      : title.length > 40
          ? '"${title.substring(0, 39)}…"'
          : '"$title"';

  factory PlanTask.fromJira(JiraIssue issue) => PlanTask(
        source: TaskSource.jira,
        ref: issue.key.toUpperCase(),
        label: issue.key,
        title: issue.summary,
        description: issue.fullDescription.isNotEmpty ? issue.fullDescription : issue.description,
        status: issue.status,
        statusCategory: issue.statusCategory,
        type: issue.issueType,
        priority: issue.priority,
        place: issue.projectName,
        due: issue.dueDate,
        assignedAt: issue.assignedAt,
        originalEstimateMinutes: issue.originalEstimateMinutes,
        remainingEstimateMinutes: issue.remainingEstimateMinutes,
        timeSpentMinutes: issue.timeSpentMinutes,
        jira: issue,
      );

  factory PlanTask.fromTrello(TrelloCard card) {
    final list = card.listName;
    return PlanTask(
      source: TaskSource.trello,
      ref: 'TRELLO-${card.id.toUpperCase()}',
      label: card.idShort == null ? '' : '#${card.idShort}',
      title: card.name,
      description: card.shortDescription,
      status: list,
      statusCategory: _trelloDone.hasMatch(list)
          ? 'done'
          : _trelloDoing.hasMatch(list)
              ? 'indeterminate'
              : 'new',
      priority: _trelloPriority(card),
      place: card.boardName,
      due: card.due == null || card.dueComplete ? null : card.due!.toLocal(),
      trello: card,
    );
  }
}

final _trelloDone = RegExp(r'\b(done|complete|completed|closed|finished|shipped|released|archived?)\b',
    caseSensitive: false);
final _trelloDoing = RegExp(r'doing|progress|\bwip\b|working|develop|current|started|active', caseSensitive: false);

/// Trello has no priority field; labels often stand in for one.
String _trelloPriority(TrelloCard card) {
  final names = card.labels.map((l) => l.name.toLowerCase()).join(' ');
  if (RegExp(r'urgent|critical|blocker|highest|asap|p0').hasMatch(names)) return 'Highest';
  if (RegExp(r'\bhigh|important|p1').hasMatch(names)) return 'High';
  if (RegExp(r'\blow|minor|nice to have|p3').hasMatch(names)) return 'Low';
  return '';
}

/// One task in the plan, with why it's there and how long to give it.
class PlanItem {
  const PlanItem({
    required this.task,
    required this.score,
    required this.suggestedMinutes,
    required this.loggedMinutes,
    required this.loggedTodayMinutes,
    required this.reasons,
    this.lastProjectId,
    this.aiReason,
  });

  final PlanTask task;

  /// Higher goes first.
  final int score;

  /// Time to give it today.
  final int suggestedMinutes;

  /// Time already tracked against it (entries that name it).
  final int loggedMinutes;
  final int loggedTodayMinutes;

  /// Short rule-based reasons, e.g. "In progress", "Due tomorrow".
  final List<String> reasons;

  /// Project of the latest entry for this task, to preselect on Start.
  final int? lastProjectId;

  /// Claude's reason, when the plan came from Claude.
  final String? aiReason;

  PlanItem copyWith({int? suggestedMinutes, String? aiReason}) => PlanItem(
        task: task,
        score: score,
        suggestedMinutes: suggestedMinutes ?? this.suggestedMinutes,
        loggedMinutes: loggedMinutes,
        loggedTodayMinutes: loggedTodayMinutes,
        reasons: reasons,
        lastProjectId: lastProjectId,
        aiReason: aiReason ?? this.aiReason,
      );
}

enum NudgeKind { overtime, wip, overdue, stale, overrun, local }

/// A short heads-up shown above the plan.
class PlanNudge {
  const PlanNudge(this.kind, this.text);

  final NudgeKind kind;
  final String text;
}

class DayPlan {
  const DayPlan({
    required this.day,
    required this.trackedMinutes,
    required this.today,
    required this.later,
    required this.waiting,
    required this.nudges,
    this.capacityMinutes = dayCapacityMinutes,
    this.aiNote,
    this.related = const [],
  });

  final DateTime day;

  /// Already tracked today (entries, local entries and a running timer).
  final int trackedMinutes;
  final int capacityMinutes;

  /// What fits in today, in order.
  final List<PlanItem> today;

  /// Doesn't fit today.
  final List<PlanItem> later;

  /// In a review / test / blocked column: someone else's move.
  final List<PlanItem> waiting;
  final List<PlanNudge> nudges;

  /// Claude's advice for the day, when the plan came from Claude.
  final String? aiNote;

  /// Jira issues your entries name that aren't to plan (done, or no longer
  /// on your list), so the standup can still say where they are now.
  final List<PlanTask> related;

  List<PlanItem> get all => [...today, ...later, ...waiting];
  int get plannedMinutes => today.fold(0, (sum, i) => sum + i.suggestedMinutes);
  int get freeMinutes => math.max(0, capacityMinutes - trackedMinutes - plannedMinutes);
  bool get fromClaude => aiNote != null;
}

final _waitingStatus = RegExp(r'review|test|qa\b|verif|approv|block|waiting|on hold', caseSensitive: false);
final _blockedStatus = RegExp(r'block|on hold|waiting|impediment', caseSensitive: false);

/// In a column where the next move is someone else's (review, QA, blocked…).
bool isWaitingStatus(JiraIssue issue) => _waitingStatus.hasMatch(issue.status);
bool _isWaiting(PlanTask task) => task.status.isNotEmpty && _waitingStatus.hasMatch(task.status);

final _anyJiraKey = RegExp(r'(^|[^A-Za-z0-9])([A-Z][A-Z0-9]+-[0-9]+)(?![0-9])');

/// Jira keys named in [text] ("CDEV-12 fix" → CDEV-12).
Iterable<String> jiraKeysIn(String text) => _anyJiraKey.allMatches(text).map((m) => m.group(2)!);

/// Jira keys in the titles of entries from the last [recentWorkDays] days.
Set<String> recentJiraKeys(List<TimeEntry> entries, DateTime now) {
  final since = dateKey(dateOnly(now).subtract(const Duration(days: recentWorkDays)));
  return {
    for (final e in entries)
      if (e.date.compareTo(since) >= 0) ...jiraKeysIn(e.taskTitle),
  };
}

/// Whether [title] mentions [key] as a whole key ("CDEV-12" but not "CDEV-123").
bool titleHasKey(String title, String key) =>
    RegExp('(^|[^A-Za-z0-9])${RegExp.escape(key)}(?![0-9])', caseSensitive: false).hasMatch(title);

String _normalize(String text) => text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

/// Whether [entry] is time spent on [task].
bool entryIsFor(TimeEntry entry, PlanTask task) => switch (task.source) {
      TaskSource.jira => titleHasKey(entry.taskTitle, task.label),
      TaskSource.trello => _isForCard(entry, task.trello!),
      TaskSource.entries => _normalize(entry.taskTitle) == _normalize(task.title),
    };

bool _isForCard(TimeEntry entry, TrelloCard card) {
  final name = _normalize(card.name);
  final title = _normalize(entry.taskTitle);
  if (name.length >= 4 && (title == name || title.contains(name))) return true;
  return card.url.isNotEmpty && (entry.description ?? '').contains(card.url);
}

int _roundTo15(int minutes) => math.max(15, (minutes / 15).round() * 15);

/// Time to give [issue] today: what's left of its estimate, else a typical
/// amount for its type; between 30m and 4h.
int suggestedMinutesFor(JiraIssue issue, int loggedMinutes) =>
    _suggestedMinutes(PlanTask.fromJira(issue), loggedMinutes);

int _suggestedMinutes(PlanTask task, int loggedMinutes) {
  final spent = task.timeSpentMinutes ?? loggedMinutes;
  final left = task.remainingEstimateMinutes ??
      (task.originalEstimateMinutes != null ? task.originalEstimateMinutes! - spent : null);
  final type = task.type.toLowerCase();
  final typical = type.contains('bug')
      ? 90
      : type.contains('sub')
          ? 60
          : type.contains('story')
              ? 180
              : 120;
  final minutes = left != null && left > 0 ? left : typical;
  return _roundTo15(minutes.clamp(30, 240));
}

/// Meetings and other routine entries aren't work to plan.
final _routine = RegExp(
    r'\b(stand-?ups?|daily|meetings?|calls?|syncs?|retros?|retrospectives?|planning|1:1s?|one on ones?|lunch|breaks?|interviews?|grooming|refinement|demos?)\b',
    caseSensitive: false);

/// How far back recent work is looked for.
const recentWorkDays = 14;

/// Work from your recent entries that isn't one of the [known] tasks, one
/// task per title: its latest note becomes the description. With
/// [jiraConnected], entries naming any Jira key belong to Jira (open or
/// done), so they never count as recent work.
List<PlanTask> recentWorkTasks(
  List<TimeEntry> entries,
  List<PlanTask> known,
  DateTime now, {
  bool jiraConnected = false,
}) {
  final today = dateOnly(now);
  final since = dateKey(today.subtract(const Duration(days: recentWorkDays)));
  final groups = <String, List<TimeEntry>>{};
  for (final e in entries) {
    final title = e.taskTitle.trim();
    if (title.isEmpty || e.date.compareTo(since) < 0 || _routine.hasMatch(title)) continue;
    if (jiraConnected && jiraKeysIn(title).isNotEmpty) continue;
    if (known.any((t) => entryIsFor(e, t))) continue;
    groups.putIfAbsent(_normalize(title), () => []).add(e);
  }
  return [
    for (final list in groups.values)
      () {
        list.sort((a, b) {
          final byDate = b.date.compareTo(a.date);
          return byDate != 0 ? byDate : (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0));
        });
        final note = list.map((e) => e.description?.trim() ?? '').firstWhere((d) => d.isNotEmpty, orElse: () => '');
        final days = list.map((e) => e.date).toSet().length;
        final last = parseDateKey(list.first.date);
        return PlanTask(
          source: TaskSource.entries,
          ref: 'WORK-${_hash(_normalize(list.first.taskTitle))}',
          title: list.first.taskTitle.trim(),
          description: note,
          statusCategory: today.difference(last).inDays <= 3 ? 'indeterminate' : 'new',
          place: list.first.project?.name ?? '',
          lastWorked: last,
          daysWorked: days,
        );
      }(),
  ];
}

/// Short, stable id for a title (FNV-1a), so Claude can refer to it.
String _hash(String text) {
  var h = 0x811c9dc5;
  for (final c in text.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(16).toUpperCase().padLeft(8, '0');
}

/// Builds today's plan from your Jira issues, Trello cards and the work in
/// your recent entries, and the time already tracked.
///
/// Tasks are ranked by priority, being in progress, due date, how long
/// they've been yours and whether you've touched them today (recent work by
/// how recently you worked on it), then fill the day's free time. Tasks
/// waiting on review/test are listed apart.
DayPlan buildDayPlan({
  List<JiraIssue> issues = const [],
  List<TrelloCard> cards = const [],
  List<JiraIssue> relatedIssues = const [],
  bool jiraConnected = false,
  required List<TimeEntry> entries,
  required DateTime now,
  String? myAccountId,
  String? trelloMemberId,
  bool includeRecentWork = true,
  int runningMinutes = 0,
  int localEntryCount = 0,
}) {
  final today = dateOnly(now);
  final todayKey = dateKey(today);
  final tracked = entries.where((e) => e.date == todayKey).fold<int>(0, (sum, e) => sum + e.totalMinutes) +
      runningMinutes;

  final known = <PlanTask>[
    for (final issue in issues) PlanTask.fromJira(issue),
    for (final card in cards)
      // Only cards on you (when we know who you are).
      if (trelloMemberId == null || trelloMemberId.isEmpty || card.memberIds.contains(trelloMemberId))
        PlanTask.fromTrello(card),
  ];
  // Issues your entries name that aren't on your open list: never planned,
  // but they keep that work out of "recent work" and tell the standup
  // where it is now.
  final openKeys = {for (final i in issues) i.key.toUpperCase()};
  final related = [
    for (final i in relatedIssues)
      if (!openKeys.contains(i.key.toUpperCase())) PlanTask.fromJira(i),
  ];
  final tasks = [
    ...known,
    if (includeRecentWork)
      ...recentWorkTasks(entries, [...known, ...related], now,
          jiraConnected: jiraConnected || issues.isNotEmpty || relatedIssues.isNotEmpty),
  ];

  final candidates = <PlanItem>[];
  final waiting = <PlanItem>[];
  for (final task in tasks) {
    if (task.statusCategory == 'done') continue;
    final mine = [for (final e in entries) if (entryIsFor(e, task)) e];
    final logged = mine.fold<int>(0, (sum, e) => sum + e.totalMinutes);
    final loggedToday = mine.where((e) => e.date == todayKey).fold<int>(0, (sum, e) => sum + e.totalMinutes);
    mine.sort((a, b) {
      final byDate = b.date.compareTo(a.date);
      return byDate != 0 ? byDate : (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0));
    });

    final reasons = <String>[];
    var score = 0;
    int suggested;
    if (task.source == TaskSource.entries) {
      // Recent work: carry on with what you were doing.
      final daysAgo = today.difference(task.lastWorked ?? today).inDays;
      score = 15 + (daysAgo <= 1 ? 25 : daysAgo <= 3 ? 15 : 0) + math.min(task.daysWorked, 5) * 2;
      reasons.add(switch (daysAgo) {
        0 => 'Worked on today',
        1 => 'Worked on yesterday',
        _ => 'Last worked ${DateFormat('EEE d').format(task.lastWorked!)}',
      });
      // About what a day of it usually takes.
      final perDay = task.daysWorked == 0 ? 120 : logged ~/ task.daysWorked;
      suggested = _roundTo15(perDay.clamp(30, 240));
    } else {
      score = switch (task.priorityRank) {
        0 => 50,
        1 => 40,
        2 => 25,
        3 => 12,
        _ => 5,
      };
      if (task.priorityRank <= 1 && task.priority.isNotEmpty) reasons.add('${task.priority} priority');
      if (task.statusCategory == 'indeterminate' && !_isWaiting(task)) {
        score += 30;
        reasons.add('In progress');
      }
      final due = task.due == null ? null : dateOnly(task.due!);
      if (due != null) {
        final days = due.difference(today).inDays;
        if (days < 0) {
          score += 45;
          reasons.add('Overdue ${-days}d');
        } else if (days == 0) {
          score += 40;
          reasons.add('Due today');
        } else if (days == 1) {
          score += 30;
          reasons.add('Due tomorrow');
        } else if (days <= 3) {
          score += 20;
          reasons.add('Due in ${days}d');
        } else if (days <= 7) {
          score += 10;
          reasons.add('Due ${DateFormat('EEE').format(due)}');
        }
      }
      final assigned = task.jira != null && task.jira!.assigneeAccountId != null &&
              task.jira!.assigneeAccountId == myAccountId
          ? task.assignedAt
          : null;
      final age = assigned == null ? 0 : today.difference(dateOnly(assigned.toLocal())).inDays;
      score += math.min(age, 30) ~/ 3;
      if (age >= 7) reasons.add('Yours ${age}d');
      if (loggedToday > 0) {
        score += 8;
        reasons.add('Worked on today');
      }
      suggested = _suggestedMinutes(task, logged);
    }

    final item = PlanItem(
      task: task,
      score: score,
      suggestedMinutes: suggested,
      loggedMinutes: logged,
      loggedTodayMinutes: loggedToday,
      reasons: reasons,
      lastProjectId: mine.isEmpty ? null : mine.first.projectId,
    );
    (_isWaiting(task) ? waiting : candidates).add(item);
  }

  // Highest score first; ties keep the sources' order (recently updated first).
  final ranked = [for (var i = 0; i < candidates.length; i++) (i, candidates[i])]
    ..sort((a, b) {
      final byScore = b.$2.score.compareTo(a.$2.score);
      return byScore != 0 ? byScore : a.$1.compareTo(b.$1);
    });

  var free = math.max(0, dayCapacityMinutes - tracked);
  final planned = <PlanItem>[];
  final later = <PlanItem>[];
  for (final (_, item) in ranked) {
    if (free >= 15) {
      final take = math.min(item.suggestedMinutes, (free ~/ 15) * 15);
      planned.add(item.copyWith(suggestedMinutes: take));
      free -= take;
    } else {
      later.add(item);
    }
  }

  return DayPlan(
    day: today,
    trackedMinutes: tracked,
    today: planned,
    later: later,
    waiting: waiting,
    nudges: _nudges(
      all: [...candidates, ...waiting],
      inProgress: candidates
          .where((i) => i.task.source != TaskSource.entries && i.task.statusCategory == 'indeterminate')
          .length,
      tracked: tracked,
      today: today,
      myAccountId: myAccountId,
      localEntryCount: localEntryCount,
    ),
    related: related,
  );
}

List<PlanNudge> _nudges({
  required List<PlanItem> all,
  required int inProgress,
  required int tracked,
  required DateTime today,
  required String? myAccountId,
  required int localEntryCount,
}) {
  String listNames(List<String> names) => switch (names.length) {
        1 => names[0],
        2 => '${names[0]} and ${names[1]}',
        _ => '${names[0]}, ${names[1]} and ${names.length - 2} more',
      };

  final nudges = <PlanNudge>[];
  if (tracked > dayCapacityMinutes) {
    nudges.add(PlanNudge(
      NudgeKind.overtime,
      "You're ${formatMinutes(tracked - dayCapacityMinutes)} into overtime today.",
    ));
  }

  final overdue = [
    for (final i in all)
      if (i.task.due != null && dateOnly(i.task.due!).isBefore(today)) i,
  ];
  if (overdue.length == 1) {
    final due = DateFormat('MMM d').format(overdue.first.task.due!);
    nudges.add(PlanNudge(NudgeKind.overdue, '${overdue.first.task.shortName} is overdue (was due $due).'));
  } else if (overdue.length > 1) {
    nudges.add(PlanNudge(NudgeKind.overdue, '${listNames([for (final i in overdue) i.task.shortName])} are overdue.'));
  }

  if (inProgress >= 3) {
    nudges.add(PlanNudge(
      NudgeKind.wip,
      '$inProgress tasks are in progress at once. Finishing one before starting another keeps the day focused.',
    ));
  }

  final stale = <PlanItem>[];
  for (final i in all) {
    final assigned = i.task.jira?.assigneeAccountId == myAccountId ? i.task.assignedAt : null;
    if (assigned == null || i.loggedMinutes > 0 || (i.task.timeSpentMinutes ?? 0) > 0) continue;
    if (today.difference(dateOnly(assigned.toLocal())).inDays >= 10) stale.add(i);
  }
  if (stale.length == 1) {
    final days = today.difference(dateOnly(stale.first.task.assignedAt!.toLocal())).inDays;
    nudges.add(PlanNudge(
      NudgeKind.stale,
      '${stale.first.task.shortName} has been yours $days days with no time logged.',
    ));
  } else if (stale.length > 1) {
    nudges.add(PlanNudge(
      NudgeKind.stale,
      '${listNames([for (final i in stale) i.task.shortName])} have been yours 10+ days with no time logged.',
    ));
  }

  for (final i in all) {
    final estimate = i.task.originalEstimateMinutes;
    final spent = i.task.timeSpentMinutes ?? i.loggedMinutes;
    if (estimate != null && estimate > 0 && spent > estimate * 1.25) {
      nudges.add(PlanNudge(
        NudgeKind.overrun,
        '${i.task.shortName}: ${formatMinutes(spent)} logged against a ${formatMinutes(estimate)} estimate.',
      ));
      break; // One is enough of a hint.
    }
  }

  if (localEntryCount > 0) {
    nudges.add(PlanNudge(
      NudgeKind.local,
      '$localEntryCount ${localEntryCount == 1 ? 'entry is' : 'entries are'} only on this Mac. '
      'Upload from Entries when ready.',
    ));
  }
  return nudges;
}

/// Claude's choice for one task.
class ClaudePlanStep {
  const ClaudePlanStep({required this.key, required this.minutes, required this.reason});

  final String key;
  final int minutes;
  final String reason;
}

/// JSON Schema for Claude's plan answer.
const claudePlanSchema = <String, dynamic>{
  'type': 'object',
  'properties': {
    'plan': {
      'type': 'array',
      'items': {
        'type': 'object',
        'properties': {
          'key': {'type': 'string'},
          'minutes': {'type': 'integer'},
          'reason': {'type': 'string'},
        },
        'required': ['key', 'minutes', 'reason'],
      },
    },
    'note': {'type': 'string'},
  },
  'required': ['plan', 'note'],
};

List<ClaudePlanStep> parseClaudePlan(Map<String, dynamic> json) => [
      for (final step in json['plan'] as List<dynamic>? ?? const [])
        if (step is Map && step['key'] is String)
          ClaudePlanStep(
            key: (step['key'] as String).trim().toUpperCase(),
            minutes: (step['minutes'] as num?)?.toInt() ?? 60,
            reason: (step['reason'] as String? ?? '').trim(),
          ),
    ];

/// [plan] reordered by Claude: its picks (in its order and with its times)
/// become today; everything else goes back to later / waiting.
DayPlan applyClaudePlan(DayPlan plan, List<ClaudePlanStep> steps, String note) {
  final byKey = {for (final i in plan.all) i.task.ref.toUpperCase(): i};
  final picked = <PlanItem>[];
  final used = <String>{};
  for (final step in steps) {
    final item = byKey[step.key];
    if (item == null || !used.add(step.key)) continue;
    picked.add(item.copyWith(
      suggestedMinutes: _roundTo15(step.minutes.clamp(15, dayCapacityMinutes)),
      aiReason: step.reason.isEmpty ? null : step.reason,
    ));
  }
  bool rest(PlanItem i) => !used.contains(i.task.ref.toUpperCase());
  return DayPlan(
    day: plan.day,
    trackedMinutes: plan.trackedMinutes,
    capacityMinutes: plan.capacityMinutes,
    today: picked,
    later: [...plan.today.where(rest), ...plan.later.where(rest)],
    waiting: plan.waiting.where(rest).toList(),
    nudges: plan.nudges,
    aiNote: note.trim().isEmpty ? 'Planned with Claude.' : note.trim(),
    related: plan.related,
  );
}

String _clip(String text, int max) => text.length > max ? '${text.substring(0, max)}…' : text;

/// What Claude gets to plan with: every task (Jira, Trello, recent work with
/// your notes) and the day so far.
Map<String, dynamic> claudePlanInput(DayPlan plan, DateTime now) {
  final today = dateOnly(now);
  Map<String, dynamic> task(PlanItem i, {required bool waiting}) {
    final t = i.task;
    return {
      'key': t.ref,
      'source': t.source.name,
      if (t.label.isNotEmpty && t.label.toUpperCase() != t.ref) 'label': t.label,
      'title': t.title,
      if (t.type.isNotEmpty) 'type': t.type,
      if (t.status.isNotEmpty) 'status': t.status,
      'waitingOnOthers': waiting,
      if (t.priority.isNotEmpty) 'priority': t.priority,
      if (t.place.isNotEmpty) 'project': t.place,
      if (t.due != null) 'due': dateKey(t.due!),
      if (t.originalEstimateMinutes != null) 'estimateMinutes': t.originalEstimateMinutes,
      if (t.remainingEstimateMinutes != null) 'remainingMinutes': t.remainingEstimateMinutes,
      'loggedMinutes': t.timeSpentMinutes ?? i.loggedMinutes,
      'loggedTodayMinutes': i.loggedTodayMinutes,
      if (t.assignedAt != null) 'assignedDaysAgo': today.difference(dateOnly(t.assignedAt!.toLocal())).inDays,
      if (t.lastWorked != null) 'lastWorkedDaysAgo': today.difference(t.lastWorked!).inDays,
      if (t.daysWorked > 0) 'daysWorkedLately': t.daysWorked,
      if (t.description.isNotEmpty)
        (t.source == TaskSource.entries ? 'lastNote' : 'description'): _clip(t.description, 300),
    };
  }

  return {
    'today': DateFormat('EEEE, yyyy-MM-dd').format(now),
    'workdayMinutes': plan.capacityMinutes,
    'alreadyTrackedTodayMinutes': plan.trackedMinutes,
    'freeMinutesToPlan': math.max(0, plan.capacityMinutes - plan.trackedMinutes),
    'tasks': [
      for (final i in [...plan.today, ...plan.later]) task(i, waiting: false),
      for (final i in plan.waiting) task(i, waiting: true),
    ],
  };
}

const claudePlanInstruction =
    'You are planning a software developer\'s working day. The JSON on stdin lists their tasks from up '
    'to three sources: Jira issues ("jira"), Trello cards ("trello") and recent work found in their own '
    'time entries ("entries", with the last note they wrote, or only a title). It also gives the time '
    'already tracked today and the free minutes left. Choose and order the tasks to work on today; the '
    'minutes you give them must add up to no more than freeMinutesToPlan. Prefer finishing work already '
    'in progress, then urgent priorities and due dates. Use descriptions and notes to judge what is left: '
    'skip recent work whose last note says it is finished, and continue work left half-done. If a Jira or '
    'Trello task and recent work look like the same thing, plan the Jira or Trello one. Only include '
    'tasks waiting on others (review, test) if they likely need action. Give each task a reason of at '
    'most 12 words. In "note", give one or two sentences of practical advice for the day. Use only '
    '"key" values from the input.';

// ---------------------------------------------------------------------------
// Standup

/// One line of work for a standup: a task title with its total time, and the
/// Jira issue or Trello card it was on, when known.
class StandupLine {
  const StandupLine({required this.title, required this.minutes, this.description, this.project, this.task});

  final String title;
  final int minutes;

  /// The note written on the entries (the first one found).
  final String? description;
  final String? project;

  /// The Jira issue or Trello card, with its current status.
  final PlanTask? task;
}

/// The previous working day's work, today's so far, the plan, and what's
/// stuck.
class StandupData {
  const StandupData({
    required this.previousDay,
    required this.previous,
    required this.today,
    required this.planned,
    this.blocked = const [],
    this.waiting = const [],
  });

  /// Most recent day before today with tracked time.
  final DateTime? previousDay;
  final List<StandupLine> previous;
  final List<StandupLine> today;
  final List<PlanItem> planned;

  /// Tasks in a blocked / on-hold column.
  final List<PlanItem> blocked;

  /// Tasks waiting on review or test.
  final List<PlanItem> waiting;
}

List<StandupLine> _linesFor(Iterable<TimeEntry> entries, List<PlanTask> tasks) {
  final byTitle = <String, List<TimeEntry>>{};
  for (final e in entries) {
    byTitle.putIfAbsent(e.taskTitle.trim(), () => []).add(e);
  }
  final lines = <StandupLine>[];
  byTitle.forEach((title, list) {
    final description = list
        .map((e) => e.description?.trim() ?? '')
        .firstWhere((d) => d.isNotEmpty, orElse: () => '');
    lines.add(StandupLine(
      title: title,
      minutes: list.fold(0, (sum, e) => sum + e.totalMinutes),
      description: description.isEmpty ? null : description,
      project: list.first.project?.name,
      task: tasks.where((t) => entryIsFor(list.first, t)).firstOrNull,
    ));
  });
  return lines..sort((a, b) => b.minutes.compareTo(a.minutes));
}

StandupData standupData(List<TimeEntry> entries, DayPlan plan, DateTime now) {
  final todayKey = dateKey(dateOnly(now));
  final earlier = entries.where((e) => e.date.compareTo(todayKey) < 0).map((e) => e.date).toSet().toList()
    ..sort();
  final previousKey = earlier.isEmpty ? null : earlier.last;
  // Lines link to Jira issues and Trello cards (recent work is the entries).
  final tasks = [
    for (final i in plan.all)
      if (i.task.source != TaskSource.entries) i.task,
    ...plan.related,
  ];
  bool blocked(PlanItem i) => _blockedStatus.hasMatch(i.task.status);
  return StandupData(
    previousDay: previousKey == null ? null : parseDateKey(previousKey),
    previous: previousKey == null ? const [] : _linesFor(entries.where((e) => e.date == previousKey), tasks),
    today: _linesFor(entries.where((e) => e.date == todayKey), tasks),
    planned: plan.today.take(6).toList(),
    blocked: plan.waiting.where(blocked).toList(),
    waiting: plan.waiting.where((i) => !blocked(i)).toList(),
  );
}

/// Whether today's tracked [lines] already cover [item].
bool _covers(List<StandupLine> lines, PlanItem item) => lines.any((l) =>
    l.task?.ref == item.task.ref ||
    (item.task.source == TaskSource.entries && _normalize(l.title) == _normalize(item.task.title)));

/// A plain standup from the data, used as is or as Claude's starting point.
String standupTemplate(StandupData data, DateTime now) {
  String line(StandupLine l) {
    final status = l.task?.status ?? '';
    return '• ${l.title}${l.description != null ? ' — ${l.description}' : ''} (${formatMinutes(l.minutes)})'
        '${status.isNotEmpty ? ' · now $status' : ''}';
  }

  final previousLabel = data.previousDay == null
      ? 'Yesterday'
      : formatDay(data.previousDay!, now: now) == 'Yesterday'
          ? 'Yesterday'
          : 'Last working day (${formatDay(data.previousDay!, now: now)})';
  final todayLines = <String>[
    for (final l in data.today) line(l),
    for (final p in data.planned)
      if (!_covers(data.today, p)) '• ${p.task.displayName}',
  ];
  return [
    '$previousLabel:',
    if (data.previous.isEmpty) '• Nothing tracked' else ...data.previous.map(line),
    '',
    'Today:',
    if (todayLines.isEmpty) '• Nothing planned yet' else ...todayLines,
    '',
    'Blockers:',
    if (data.blocked.isEmpty)
      '• None'
    else
      for (final b in data.blocked) '• ${b.task.displayName} (${b.task.status})',
  ].join('\n');
}

/// What Claude gets to write the standup from: entries with your notes, the
/// Jira issues and Trello cards they were on (current status), the plan, and
/// what's blocked or waiting.
Map<String, dynamic> standupInput(StandupData data, DateTime now) {
  Map<String, dynamic> task(PlanTask t) => {
        'source': t.source.name,
        if (t.label.isNotEmpty) 'key': t.label,
        'title': t.title,
        if (t.status.isNotEmpty) 'status': t.status,
        if (t.place.isNotEmpty) 'project': t.place,
        if (t.due != null) 'due': dateKey(t.due!),
      };
  Map<String, dynamic> work(StandupLine l) => {
        'title': l.title,
        'minutes': l.minutes,
        if (l.description != null) 'note': l.description,
        if (l.project != null) 'project': l.project,
        if (l.task != null) 'task': task(l.task!),
      };
  return {
    'today': DateFormat('EEEE, yyyy-MM-dd').format(now),
    if (data.previousDay != null) 'previousWorkday': DateFormat('EEEE, yyyy-MM-dd').format(data.previousDay!),
    'previousWorkdayWork': [for (final l in data.previous) work(l)],
    'todayWorkSoFar': [for (final l in data.today) work(l)],
    'plannedToday': [
      for (final p in data.planned)
        {
          ...task(p.task),
          if (p.task.description.isNotEmpty)
            (p.task.source == TaskSource.entries ? 'lastNote' : 'description'): _clip(p.task.description, 200),
        },
    ],
    'blocked': [for (final b in data.blocked) task(b.task)],
    'waitingOnOthers': [for (final w in data.waiting) task(w.task)],
  };
}

const standupInstruction =
    'Write a short daily standup that a software developer will read out on a team call, from the JSON '
    'on stdin. It combines their time entries (titles and the notes they wrote), the Jira issues and '
    'Trello cards that work was on (with their current status), today\'s plan, and what is blocked or '
    'waiting on others. Use exactly three sections, "Yesterday:", "Today:" and "Blockers:" (if the '
    'previous workday was not yesterday, name it, e.g. "Friday:"), each followed by bullets starting '
    'with "• ". Write in the first person, in short natural sentences that are easy to say aloud. Say '
    'what got done or how far it got, using the notes and current status (e.g. "it\'s in review now"), '
    'not durations. Keep Jira keys, merge related entries, about 8 bullets in total. Under Blockers, '
    'list blocked items and anything waiting on others that holds up work; otherwise write "• None". '
    'Reply with only the standup text, no preamble.';
