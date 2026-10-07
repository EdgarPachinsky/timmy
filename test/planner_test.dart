import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timmy/core/planner.dart';
import 'package:timmy/models/jira.dart';
import 'package:timmy/models/models.dart';

final _now = DateTime(2026, 10, 8, 10, 0);

JiraIssue _issue(
  String key, {
  String summary = 'Task',
  String status = 'To Do',
  String category = 'new',
  String priority = 'Medium',
  String type = 'Task',
  DateTime? due,
  DateTime? assignedAt,
  int? remaining,
  int? original,
}) =>
    JiraIssue(
      key: key,
      summary: summary,
      status: status,
      statusCategory: category,
      priority: priority,
      issueType: type,
      dueDate: due,
      assigneeAccountId: 'me',
      assignedAt: assignedAt,
      remainingEstimateMinutes: remaining,
      originalEstimateMinutes: original,
    );

TimeEntry _entry(String title, int minutes, {String date = '2026-10-08', int projectId = 38}) => TimeEntry(
      id: 1,
      projectId: projectId,
      project: const Project(id: 38, name: 'CSS', color: Color(0xFF10B981), status: 'active'),
      taskTitle: title,
      totalMinutes: minutes,
      date: date,
      billable: true,
      tags: const [],
      createdAt: null,
    );

void main() {
  test('titleHasKey matches whole keys only', () {
    expect(titleHasKey('CDEV-12 fix login', 'CDEV-12'), isTrue);
    expect(titleHasKey('fix for cdev-12', 'CDEV-12'), isTrue);
    expect(titleHasKey('CDEV-123 other', 'CDEV-12'), isFalse);
    expect(titleHasKey('XCDEV-12', 'CDEV-12'), isFalse);
  });

  test('suggested time uses the remaining estimate, else a typical amount for the type', () {
    expect(suggestedMinutesFor(_issue('A-1', remaining: 100), 0), 105); // rounded to 15
    expect(suggestedMinutesFor(_issue('A-1', original: 180), 120), 60); // estimate minus logged
    expect(suggestedMinutesFor(_issue('A-1', type: 'Bug'), 0), 90);
    expect(suggestedMinutesFor(_issue('A-1', type: 'Story'), 0), 180);
    expect(suggestedMinutesFor(_issue('A-1', remaining: 900), 0), 240); // capped at 4h
  });

  test('ranks in-progress, urgent and due work first, and keeps review/test apart', () {
    final plan = buildDayPlan(
      issues: [
        _issue('A-1', priority: 'Low'),
        _issue('A-2', status: 'In Progress', category: 'indeterminate'),
        _issue('A-3', priority: 'Highest', due: DateTime(2026, 10, 7)),
        _issue('A-4', status: 'Ready for Test', category: 'indeterminate'),
        _issue('A-5', status: 'Done', category: 'done'),
      ],
      entries: const [],
      now: _now,
      myAccountId: 'me',
    );
    expect(plan.today.map((i) => i.issue.key), ['A-3', 'A-2', 'A-1']);
    expect(plan.today.first.reasons, containsAll(['Highest priority', 'Overdue 1d']));
    expect(plan.waiting.single.issue.key, 'A-4');
    expect([...plan.today, ...plan.later, ...plan.waiting].map((i) => i.issue.key), isNot(contains('A-5')));
  });

  test('fills only the free part of an 8h day; the rest waits for later', () {
    final plan = buildDayPlan(
      issues: [
        _issue('A-1', priority: 'High', remaining: 90),
        _issue('A-2', remaining: 90),
        _issue('A-3', remaining: 90),
      ],
      entries: [_entry('Meetings', 6 * 60)],
      now: _now,
    );
    expect(plan.trackedMinutes, 360);
    expect(plan.today.map((i) => (i.issue.key, i.suggestedMinutes)), [('A-1', 90), ('A-2', 30)]);
    expect(plan.later.single.issue.key, 'A-3');
    expect(plan.freeMinutes, 0);
  });

  test('time logged against a key counts, and remembers its project', () {
    final plan = buildDayPlan(
      issues: [_issue('A-1')],
      entries: [
        _entry('A-1 first part', 60, date: '2026-10-06', projectId: 62),
        _entry('A-1 more', 30, projectId: 38),
      ],
      now: _now,
    );
    final item = plan.today.single;
    expect(item.loggedMinutes, 90);
    expect(item.loggedTodayMinutes, 30);
    expect(item.lastProjectId, 38);
    expect(item.reasons, contains('Worked on today'));
  });

  test('nudges: overtime, overdue, too much in progress, stale tasks, local entries', () {
    final plan = buildDayPlan(
      issues: [
        _issue('A-1', status: 'In Progress', category: 'indeterminate', due: DateTime(2026, 10, 1)),
        _issue('A-2', status: 'In Progress', category: 'indeterminate'),
        _issue('A-3', status: 'In Progress', category: 'indeterminate'),
        _issue('A-4', assignedAt: DateTime(2026, 9, 20)),
      ],
      entries: [_entry('Long day', 9 * 60)],
      now: _now,
      myAccountId: 'me',
      localEntryCount: 2,
    );
    final kinds = plan.nudges.map((n) => n.kind).toList();
    expect(kinds, containsAll([
      NudgeKind.overtime,
      NudgeKind.overdue,
      NudgeKind.wip,
      NudgeKind.stale,
      NudgeKind.local,
    ]));
    expect(plan.nudges.firstWhere((n) => n.kind == NudgeKind.overtime).text, contains('1h'));
    expect(plan.nudges.firstWhere((n) => n.kind == NudgeKind.stale).text, contains('A-4'));
    expect(plan.today, isEmpty); // The day is already full.
  });

  test("Claude's plan reorders the day with its times and reasons", () {
    final plan = buildDayPlan(
      issues: [_issue('A-1', priority: 'High'), _issue('A-2'), _issue('A-3', status: 'Code Review')],
      entries: const [],
      now: _now,
    );
    final steps = parseClaudePlan({
      'plan': [
        {'key': 'a-2', 'minutes': 50, 'reason': 'Unblocks the team'},
        {'key': 'NOPE-1', 'minutes': 60, 'reason': 'Unknown key is ignored'},
      ],
      'note': 'Start with A-2.',
    });
    final ai = applyClaudePlan(plan, steps, 'Start with A-2.');
    expect(ai.today.single.issue.key, 'A-2');
    expect(ai.today.single.suggestedMinutes, 45);
    expect(ai.today.single.aiReason, 'Unblocks the team');
    expect(ai.later.single.issue.key, 'A-1');
    expect(ai.waiting.single.issue.key, 'A-3');
    expect(ai.fromClaude, isTrue);
    expect(claudePlanInput(plan, _now)['tasks'], hasLength(3));
  });

  test('standup template lists the last working day, today and the plan', () {
    final plan = buildDayPlan(issues: [_issue('A-9', summary: 'Next thing')], entries: const [], now: _now);
    final data = standupData(
      [
        _entry('A-1 login fix', 90, date: '2026-10-06'),
        _entry('A-1 login fix', 30, date: '2026-10-06'),
        _entry('Old stuff', 60, date: '2026-10-01'),
        _entry('A-2 review', 45),
      ],
      plan,
      _now,
    );
    expect(data.previousDay, DateTime(2026, 10, 6));
    final text = standupTemplate(data, _now);
    expect(text, contains('Last working day (Tue, Oct 6):'));
    expect(text, contains('• A-1 login fix (2h)'));
    expect(text, contains('• A-2 review (45m)'));
    expect(text, contains('• A-9 Next thing'));
    expect(text, contains('Blockers:'));
    expect(text, isNot(contains('Old stuff')));
  });
}
