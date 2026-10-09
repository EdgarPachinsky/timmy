import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timmy/core/entry_description.dart';
import 'package:timmy/models/jira.dart';
import 'package:timmy/models/models.dart';

TimeEntry _entry(String title, String? note, String date) => TimeEntry(
      id: 1,
      projectId: 38,
      project: const Project(id: 38, name: 'CSS', color: Color(0xFF10B981), status: 'active'),
      taskTitle: title,
      description: note,
      totalMinutes: 60,
      date: date,
      billable: true,
      tags: const [],
      createdAt: null,
    );

void main() {
  test("Claude's answer becomes one clean line", () {
    expect(cleanEntryDescription('"Fixed tab saving."\n\nMore text'), 'Fixed tab saving');
    expect(cleanEntryDescription('• Reviewed PR feedback'), 'Reviewed PR feedback');
    expect(cleanEntryDescription('Description: Added tests'), 'Added tests');
    expect(cleanEntryDescription('   '), '');
  });

  test('earlier notes come from the same title or Jira key, newest first, no repeats', () {
    final entries = [
      _entry('CDEV-1 Login', 'first part', '2026-10-05'),
      _entry('cdev-1 login', 'second part', '2026-10-07'),
      _entry('CDEV-1', 'first part', '2026-10-06'),
      _entry('Other', 'unrelated', '2026-10-07'),
      _entry('CDEV-1 Login', null, '2026-10-08'),
    ];
    expect(earlierNotesFor(entries, 'CDEV-1 Login'), ['second part', 'first part']);
  });

  test('the input carries the Jira issue and earlier notes', () {
    final input = entryDescriptionInput(
      title: 'CDEV-1 Login',
      project: 'CSS',
      minutes: 90,
      issue: const JiraIssue(key: 'CDEV-1', summary: 'Login', status: 'In Progress', description: 'Users cannot log in'),
      earlierNotes: const ['first part'],
    );
    expect(input['timeSpent'], '1h 30m');
    expect((input['jiraIssue'] as Map)['description'], 'Users cannot log in');
    expect(input['earlierNotesOnThisTask'], ['first part']);
  });
}
