import '../models/models.dart';
import 'format.dart';

/// A regular working day. Anything tracked beyond it on a day is overtime.
const regularDayMinutes = 8 * 60;

/// Overtime for one day's total, e.g. 9h → 1h, 12h → 4h, 8h 45m → 45m.
int dailyOvertime(int dayMinutes) =>
    dayMinutes > regularDayMinutes ? dayMinutes - regularDayMinutes : 0;

/// Total minutes per day (`yyyy-MM-dd`), all projects together.
Map<String, int> minutesByDay(Iterable<TimeEntry> entries) {
  final byDay = <String, int>{};
  for (final e in entries) {
    byDay[e.date] = (byDay[e.date] ?? 0) + e.totalMinutes;
  }
  return byDay;
}

class MonthOvertime {
  const MonthOvertime({
    required this.workedMinutes,
    required this.overtimeMinutes,
    required this.overtimeDays,
  });

  /// Everything tracked in the month.
  final int workedMinutes;

  /// Sum of each day's time beyond [regularDayMinutes].
  final int overtimeMinutes;

  /// Days that went over [regularDayMinutes].
  final int overtimeDays;
}

/// Overtime for the calendar month of [month] (only year and month are used).
MonthOvertime monthOvertime(Map<String, int> byDay, DateTime month) {
  var worked = 0;
  var overtime = 0;
  var days = 0;
  byDay.forEach((key, minutes) {
    final day = parseDateKey(key);
    if (day.year != month.year || day.month != month.month) return;
    worked += minutes;
    final extra = dailyOvertime(minutes);
    overtime += extra;
    if (extra > 0) days++;
  });
  return MonthOvertime(workedMinutes: worked, overtimeMinutes: overtime, overtimeDays: days);
}
