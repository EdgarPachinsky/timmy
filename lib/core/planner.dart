import 'dart:math' as math;

import 'package:intl/intl.dart';

import '../models/jira.dart';
import '../models/models.dart';
import 'format.dart';
import 'overtime.dart';

/// A day's worth of planned work (the same 8h as the overtime rule).
const dayCapacityMinutes = regularDayMinutes;

/// One task in the plan, with why it's there and how long to give it.
class PlanItem {
  const PlanItem({
    required this.issue,
    required this.score,
    required this.suggestedMinutes,
    required this.loggedMinutes,
    required this.loggedTodayMinutes,
    required this.reasons,
    this.lastProjectId,
    this.aiReason,
  });

  final JiraIssue issue;

  /// Higher goes first.
  final int score;

  /// Time to give it today.
  final int suggestedMinutes;

  /// Time already tracked against it (entries whose title has its key).
  final int loggedMinutes;
  final int loggedTodayMinutes;

  /// Short rule-based reasons, e.g. "In progress", "Due tomorrow".
  final List<String> reasons;

  /// Project of the latest entry for this task, to preselect on Start.
  final int? lastProjectId;

  /// Claude's reason, when the plan came from Claude.
  final String? aiReason;

  PlanItem copyWith({int? suggestedMinutes, String? aiReason}) => PlanItem(
        issue: issue,
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

  int get plannedMinutes => today.fold(0, (sum, i) => sum + i.suggestedMinutes);
  int get freeMinutes => math.max(0, capacityMinutes - trackedMinutes - plannedMinutes);
  bool get fromClaude => aiNote != null;
}

final _waitingStatus = RegExp(r'review|test|qa\b|verif|approv|block|waiting|on hold', caseSensitive: false);

/// In a column where the next move is someone else's (review, QA, blocked…).
bool isWaitingStatus(JiraIssue issue) => _waitingStatus.hasMatch(issue.status);

/// Whether [title] mentions [key] as a whole key ("CDEV-12" but not "CDEV-123").
bool titleHasKey(String title, String key) =>
    RegExp('(^|[^A-Za-z0-9])${RegExp.escape(key)}(?![0-9])', caseSensitive: false).hasMatch(title);

int _roundTo15(int minutes) => math.max(15, (minutes / 15).round() * 15);

/// Time to give [issue] today: what's left of its estimate, else a typical
/// amount for its type; between 30m and 4h.
int suggestedMinutesFor(JiraIssue issue, int loggedMinutes) {
  final spent = issue.timeSpentMinutes ?? loggedMinutes;
  final left = issue.remainingEstimateMinutes ??
      (issue.originalEstimateMinutes != null ? issue.originalEstimateMinutes! - spent : null);
  final type = issue.issueType.toLowerCase();
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

/// Builds today's plan from the user's Jira tasks and tracked time.
///
/// Tasks are ranked by priority, being in progress, due date, how long
/// they've been yours and whether you've touched them today, then fill the
/// day's free time. Tasks waiting on review/test are listed apart.
DayPlan buildDayPlan({
  required List<JiraIssue> issues,
  required List<TimeEntry> entries,
  required DateTime now,
  String? myAccountId,
  int runningMinutes = 0,
  int localEntryCount = 0,
}) {
  final today = dateOnly(now);
  final todayKey = dateKey(today);
  final tracked = entries.where((e) => e.date == todayKey).fold<int>(0, (sum, e) => sum + e.totalMinutes) +
      runningMinutes;

  final candidates = <PlanItem>[];
  final waiting = <PlanItem>[];
  for (final issue in issues) {
    if (issue.statusCategory == 'done') continue;
    final mine = [for (final e in entries) if (titleHasKey(e.taskTitle, issue.key)) e];
    final logged = mine.fold<int>(0, (sum, e) => sum + e.totalMinutes);
    final loggedToday = mine.where((e) => e.date == todayKey).fold<int>(0, (sum, e) => sum + e.totalMinutes);
    mine.sort((a, b) {
      final byDate = b.date.compareTo(a.date);
      return byDate != 0 ? byDate : (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0));
    });

    final reasons = <String>[];
    var score = switch (issue.priorityRank) {
      0 => 50,
      1 => 40,
      2 => 25,
      3 => 12,
      _ => 5,
    };
    if (issue.priorityRank <= 1 && issue.priority.isNotEmpty) reasons.add('${issue.priority} priority');
    if (issue.statusCategory == 'indeterminate' && !isWaitingStatus(issue)) {
      score += 30;
      reasons.add('In progress');
    }
    final due = issue.dueDate == null ? null : dateOnly(issue.dueDate!);
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
    final assigned = issue.assigneeAccountId != null && issue.assigneeAccountId == myAccountId
        ? issue.assignedAt
        : null;
    final age = assigned == null ? 0 : today.difference(dateOnly(assigned.toLocal())).inDays;
    score += math.min(age, 30) ~/ 3;
    if (age >= 7) reasons.add('Yours ${age}d');
    if (loggedToday > 0) {
      score += 8;
      reasons.add('Worked on today');
    }

    final item = PlanItem(
      issue: issue,
      score: score,
      suggestedMinutes: suggestedMinutesFor(issue, logged),
      loggedMinutes: logged,
      loggedTodayMinutes: loggedToday,
      reasons: reasons,
      lastProjectId: mine.isEmpty ? null : mine.first.projectId,
    );
    (isWaitingStatus(issue) ? waiting : candidates).add(item);
  }

  // Highest score first; ties keep Jira's order (recently updated first).
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
      inProgress: candidates.where((i) => i.issue.statusCategory == 'indeterminate').length,
      tracked: tracked,
      today: today,
      myAccountId: myAccountId,
      localEntryCount: localEntryCount,
    ),
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
  String listKeys(List<String> keys) => switch (keys.length) {
        1 => keys[0],
        2 => '${keys[0]} and ${keys[1]}',
        _ => '${keys[0]}, ${keys[1]} and ${keys.length - 2} more',
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
      if (i.issue.dueDate != null && dateOnly(i.issue.dueDate!).isBefore(today)) i,
  ];
  if (overdue.length == 1) {
    final due = DateFormat('MMM d').format(overdue.first.issue.dueDate!);
    nudges.add(PlanNudge(NudgeKind.overdue, '${overdue.first.issue.key} is overdue (was due $due).'));
  } else if (overdue.length > 1) {
    nudges.add(PlanNudge(NudgeKind.overdue, '${listKeys([for (final i in overdue) i.issue.key])} are overdue.'));
  }

  if (inProgress >= 3) {
    nudges.add(PlanNudge(
      NudgeKind.wip,
      '$inProgress tasks are in progress at once. Finishing one before starting another keeps the day focused.',
    ));
  }

  final stale = <PlanItem>[];
  for (final i in all) {
    final assigned = i.issue.assigneeAccountId == myAccountId ? i.issue.assignedAt : null;
    if (assigned == null || i.loggedMinutes > 0 || (i.issue.timeSpentMinutes ?? 0) > 0) continue;
    if (today.difference(dateOnly(assigned.toLocal())).inDays >= 10) stale.add(i);
  }
  if (stale.length == 1) {
    final days = today.difference(dateOnly(stale.first.issue.assignedAt!.toLocal())).inDays;
    nudges.add(PlanNudge(
      NudgeKind.stale,
      '${stale.first.issue.key} has been yours $days days with no time logged.',
    ));
  } else if (stale.length > 1) {
    nudges.add(PlanNudge(
      NudgeKind.stale,
      '${listKeys([for (final i in stale) i.issue.key])} have been yours 10+ days with no time logged.',
    ));
  }

  for (final i in all) {
    final estimate = i.issue.originalEstimateMinutes;
    final spent = i.issue.timeSpentMinutes ?? i.loggedMinutes;
    if (estimate != null && estimate > 0 && spent > estimate * 1.25) {
      nudges.add(PlanNudge(
        NudgeKind.overrun,
        '${i.issue.key}: ${formatMinutes(spent)} logged against a ${formatMinutes(estimate)} estimate.',
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
  final all = [...plan.today, ...plan.later, ...plan.waiting];
  final byKey = {for (final i in all) i.issue.key.toUpperCase(): i};
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
  bool rest(PlanItem i) => !used.contains(i.issue.key.toUpperCase());
  return DayPlan(
    day: plan.day,
    trackedMinutes: plan.trackedMinutes,
    capacityMinutes: plan.capacityMinutes,
    today: picked,
    later: [...plan.today.where(rest), ...plan.later.where(rest)],
    waiting: plan.waiting.where(rest).toList(),
    nudges: plan.nudges,
    aiNote: note.trim().isEmpty ? 'Planned with Claude.' : note.trim(),
  );
}

/// What Claude gets to plan with: the tasks and the day so far.
Map<String, dynamic> claudePlanInput(DayPlan plan, DateTime now) {
  Map<String, dynamic> task(PlanItem i, {required bool waiting}) {
    final issue = i.issue;
    final description = issue.fullDescription.isNotEmpty ? issue.fullDescription : issue.description;
    return {
      'key': issue.key,
      'title': issue.summary,
      'type': issue.issueType,
      'status': issue.status,
      'waitingOnOthers': waiting,
      'priority': issue.priority,
      if (issue.dueDate != null) 'due': dateKey(issue.dueDate!),
      if (issue.originalEstimateMinutes != null) 'estimateMinutes': issue.originalEstimateMinutes,
      if (issue.remainingEstimateMinutes != null) 'remainingMinutes': issue.remainingEstimateMinutes,
      'loggedMinutes': issue.timeSpentMinutes ?? i.loggedMinutes,
      'loggedTodayMinutes': i.loggedTodayMinutes,
      if (issue.assignedAt != null)
        'assignedDaysAgo': dateOnly(now).difference(dateOnly(issue.assignedAt!.toLocal())).inDays,
      if (description.isNotEmpty)
        'description': description.length > 300 ? '${description.substring(0, 300)}…' : description,
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
    'You are planning a software developer\'s working day. The JSON on stdin lists the Jira tasks '
    'assigned to them, the time already tracked today and the free minutes left. Choose and order '
    'the tasks to work on today; the minutes you give them must add up to no more than '
    'freeMinutesToPlan. Prefer finishing work already in progress, then urgent priorities and due '
    'dates; only include tasks waiting on others (review, test) if they likely need action. Give each '
    'task a reason of at most 12 words. In "note", give one or two sentences of practical advice '
    'for the day. Use only task keys from the input.';

// ---------------------------------------------------------------------------
// Standup

/// One line of work for a standup: a task title with its total time.
class StandupLine {
  const StandupLine({required this.title, required this.minutes, this.description, this.project});

  final String title;
  final int minutes;
  final String? description;
  final String? project;
}

/// The previous working day's work, today's so far, and the plan.
class StandupData {
  const StandupData({
    required this.previousDay,
    required this.previous,
    required this.today,
    required this.planned,
  });

  /// Most recent day before today with tracked time.
  final DateTime? previousDay;
  final List<StandupLine> previous;
  final List<StandupLine> today;
  final List<PlanItem> planned;
}

List<StandupLine> _linesFor(Iterable<TimeEntry> entries) {
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
    ));
  });
  return lines..sort((a, b) => b.minutes.compareTo(a.minutes));
}

StandupData standupData(List<TimeEntry> entries, DayPlan plan, DateTime now) {
  final todayKey = dateKey(dateOnly(now));
  final earlier = entries.where((e) => e.date.compareTo(todayKey) < 0).map((e) => e.date).toSet().toList()
    ..sort();
  final previousKey = earlier.isEmpty ? null : earlier.last;
  return StandupData(
    previousDay: previousKey == null ? null : parseDateKey(previousKey),
    previous: previousKey == null ? const [] : _linesFor(entries.where((e) => e.date == previousKey)),
    today: _linesFor(entries.where((e) => e.date == todayKey)),
    planned: plan.today.take(5).toList(),
  );
}

/// A plain standup from the data, used as is or as Claude's starting point.
String standupTemplate(StandupData data, DateTime now) {
  String line(StandupLine l) =>
      '• ${l.title}${l.description != null ? ' — ${l.description}' : ''} (${formatMinutes(l.minutes)})';
  final previousLabel = data.previousDay == null
      ? 'Yesterday'
      : formatDay(data.previousDay!, now: now) == 'Yesterday'
          ? 'Yesterday'
          : 'Last working day (${formatDay(data.previousDay!, now: now)})';
  final todayLines = <String>[
    for (final l in data.today) line(l),
    for (final p in data.planned)
      if (!data.today.any((l) => titleHasKey(l.title, p.issue.key))) '• ${p.issue.key} ${p.issue.summary}',
  ];
  return [
    '$previousLabel:',
    if (data.previous.isEmpty) '• Nothing tracked' else ...data.previous.map(line),
    '',
    'Today:',
    if (todayLines.isEmpty) '• Nothing planned yet' else ...todayLines,
    '',
    'Blockers:',
    '• None',
  ].join('\n');
}

/// What Claude gets to write the standup from.
Map<String, dynamic> standupInput(StandupData data, DateTime now) {
  Map<String, dynamic> work(StandupLine l) => {
        'title': l.title,
        'minutes': l.minutes,
        if (l.description != null) 'description': l.description,
        if (l.project != null) 'project': l.project,
      };
  return {
    'today': DateFormat('EEEE, yyyy-MM-dd').format(now),
    if (data.previousDay != null) 'previousWorkday': DateFormat('EEEE, yyyy-MM-dd').format(data.previousDay!),
    'previousWorkdayEntries': [for (final l in data.previous) work(l)],
    'todayEntriesSoFar': [for (final l in data.today) work(l)],
    'plannedToday': [
      for (final p in data.planned)
        {
          'key': p.issue.key,
          'title': p.issue.summary,
          'status': p.issue.status,
          if (p.issue.dueDate != null) 'due': dateKey(p.issue.dueDate!),
        },
    ],
  };
}

const standupInstruction =
    'Write a short daily standup for a software developer from the JSON on stdin. Use exactly three '
    'sections, "Yesterday:", "Today:" and "Blockers:" (if the previous workday was not yesterday, name '
    'it, e.g. "Friday:"), each followed by plain-text bullets starting with "• ". Keep Jira keys, merge '
    'related entries, keep it to about 8 bullets in total and skip durations unless useful. If no '
    'blockers are evident, write "• None". Reply with only the standup text, no preamble.';
