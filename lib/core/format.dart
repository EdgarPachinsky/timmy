import 'package:intl/intl.dart';

/// `H:MM:SS`-style clock, e.g. `01:05:09`.
String formatClock(Duration d) {
  final total = d.isNegative ? 0 : d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(h)}:${two(m)}:${two(s)}';
}

/// `8h 30m`, `45m`, `8h`, or `0m`.
String formatMinutes(int minutes) {
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h == 0) return '${m}m';
  if (m == 0) return '${h}h';
  return '${h}h ${m}m';
}

String dateKey(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

DateTime parseDateKey(String key) => DateTime.parse(key);

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// "Today", "Yesterday", or "Tue, Jun 30" (adds the year when not current).
String formatDay(DateTime day, {DateTime? now}) {
  final today = dateOnly(now ?? DateTime.now());
  final d = dateOnly(day);
  final diff = today.difference(d).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  return DateFormat(d.year == today.year ? 'EEE, MMM d' : 'EEE, MMM d, y')
      .format(d);
}

String formatTimeOfDay(DateTime d) => DateFormat('HH:mm').format(d);
