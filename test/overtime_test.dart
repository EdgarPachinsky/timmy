import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timmy/core/overtime.dart';
import 'package:timmy/models/models.dart';

TimeEntry _entry(String date, int minutes) => TimeEntry(
      id: 1,
      projectId: 38,
      project: const Project(id: 38, name: 'CSS', color: Color(0xFF10B981), status: 'active'),
      taskTitle: 'x',
      totalMinutes: minutes,
      date: date,
      billable: true,
      tags: const [],
      createdAt: null,
    );

void main() {
  test('only time beyond 8h a day is overtime', () {
    expect(dailyOvertime(9 * 60), 60); // 9h → 8h regular + 1h overtime
    expect(dailyOvertime(12 * 60), 4 * 60); // 12h → 4h overtime
    expect(dailyOvertime(8 * 60 + 45), 45);
    expect(dailyOvertime(8 * 60), 0);
    expect(dailyOvertime(5 * 60), 0);
  });

  test('a day\'s entries are added together before comparing with 8h', () {
    final byDay = minutesByDay([
      _entry('2026-10-05', 5 * 60 + 30),
      _entry('2026-10-05', 3 * 60 + 45), // 9h 15m that day
      _entry('2026-10-06', 7 * 60),
    ]);
    expect(byDay['2026-10-05'], 9 * 60 + 15);
    expect(dailyOvertime(byDay['2026-10-05']!), 75);
  });

  test('monthly overtime sums each day\'s extra, ignoring other months', () {
    final byDay = minutesByDay([
      _entry('2026-10-01', 9 * 60), // +1h
      _entry('2026-10-02', 12 * 60), // +4h
      _entry('2026-10-03', 6 * 60), // short days don't offset overtime
      _entry('2026-10-04', 8 * 60 + 20), // +20m
      _entry('2026-09-30', 14 * 60), // September
    ]);
    final october = monthOvertime(byDay, DateTime(2026, 10));
    expect(october.overtimeMinutes, 5 * 60 + 20);
    expect(october.overtimeDays, 3);
    expect(october.workedMinutes, 9 * 60 + 12 * 60 + 6 * 60 + 8 * 60 + 20);

    expect(monthOvertime(byDay, DateTime(2026, 9)).overtimeMinutes, 6 * 60);
    expect(monthOvertime(byDay, DateTime(2026, 8)).overtimeMinutes, 0);
  });
}
