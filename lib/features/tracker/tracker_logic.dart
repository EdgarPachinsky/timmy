/// The API accepts at most 24 hours in a single time entry.
const maxEntryMinutes = 24 * 60;

/// Rounds a tracked duration to whole minutes (30s rounds up). The API rejects
/// entries shorter than one minute, so anything that rounds to 0 can't be saved.
int roundToMinutes(Duration d) => (d.inSeconds / 60).round();

class EntryChunk {
  const EntryChunk(this.date, this.minutes);

  final DateTime date;
  final int minutes;

  int get hoursPart => minutes ~/ 60;
  int get minutesPart => minutes % 60;

  @override
  bool operator ==(Object other) =>
      other is EntryChunk && other.date == date && other.minutes == minutes;

  @override
  int get hashCode => Object.hash(date, minutes);

  @override
  String toString() => 'EntryChunk($date, $minutes)';
}

/// Splits [totalMinutes] into API-sized entries of at most [maxEntryMinutes],
/// booking each successive chunk to the following calendar day.
List<EntryChunk> splitIntoEntries(DateTime startDate, int totalMinutes) {
  final chunks = <EntryChunk>[];
  var remaining = totalMinutes;
  var day = DateTime(startDate.year, startDate.month, startDate.day);
  while (remaining > 0) {
    final minutes = remaining > maxEntryMinutes ? maxEntryMinutes : remaining;
    chunks.add(EntryChunk(day, minutes));
    remaining -= minutes;
    day = DateTime(day.year, day.month, day.day + 1);
  }
  return chunks;
}
