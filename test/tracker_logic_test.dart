import 'package:flutter_test/flutter_test.dart';
import 'package:timmy/core/format.dart';
import 'package:timmy/features/tracker/tracker_logic.dart';

void main() {
  group('roundToMinutes', () {
    test('rounds to the nearest minute', () {
      expect(roundToMinutes(const Duration(seconds: 29)), 0);
      expect(roundToMinutes(const Duration(seconds: 30)), 1);
      expect(roundToMinutes(const Duration(seconds: 89)), 1);
      expect(roundToMinutes(const Duration(seconds: 90)), 2);
      expect(roundToMinutes(const Duration(hours: 2, minutes: 5)), 125);
    });
  });

  group('splitIntoEntries', () {
    final day = DateTime(2026, 10, 7);

    test('a normal duration is a single entry', () {
      final chunks = splitIntoEntries(day, 90);
      expect(chunks, [EntryChunk(day, 90)]);
      expect(chunks.single.hoursPart, 1);
      expect(chunks.single.minutesPart, 30);
    });

    test('exactly 24h is one entry of 24h 0m', () {
      final chunks = splitIntoEntries(day, 1440);
      expect(chunks, [EntryChunk(day, 1440)]);
      expect(chunks.single.hoursPart, 24);
      expect(chunks.single.minutesPart, 0);
    });

    test('longer than 24h spills onto following days', () {
      final chunks = splitIntoEntries(day, 1440 + 1440 + 45);
      expect(chunks, [
        EntryChunk(DateTime(2026, 10, 7), 1440),
        EntryChunk(DateTime(2026, 10, 8), 1440),
        EntryChunk(DateTime(2026, 10, 9), 45),
      ]);
    });

    test('rolls over month ends', () {
      final chunks = splitIntoEntries(DateTime(2026, 10, 31), 1500);
      expect(chunks.last.date, DateTime(2026, 11, 1));
    });

    test('no minutes, no entries', () {
      expect(splitIntoEntries(day, 0), isEmpty);
    });
  });

  group('formatting', () {
    test('formatClock', () {
      expect(formatClock(Duration.zero), '00:00:00');
      expect(formatClock(const Duration(hours: 1, minutes: 5, seconds: 9)), '01:05:09');
      expect(formatClock(const Duration(hours: 100)), '100:00:00');
      expect(formatClock(const Duration(seconds: -5)), '00:00:00');
    });

    test('formatMinutes', () {
      expect(formatMinutes(0), '0m');
      expect(formatMinutes(45), '45m');
      expect(formatMinutes(480), '8h');
      expect(formatMinutes(69150), '1152h 30m');
    });

    test('formatDay', () {
      final now = DateTime(2026, 10, 7, 22, 0);
      expect(formatDay(DateTime(2026, 10, 7), now: now), 'Today');
      expect(formatDay(DateTime(2026, 10, 6), now: now), 'Yesterday');
      expect(formatDay(DateTime(2026, 6, 30), now: now), 'Tue, Jun 30');
      expect(formatDay(DateTime(2025, 6, 30), now: now), 'Mon, Jun 30, 2025');
    });
  });
}
