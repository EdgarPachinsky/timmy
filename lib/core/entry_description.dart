import '../models/jira.dart';
import '../models/models.dart';
import '../models/trello.dart';
import 'format.dart';
import 'planner.dart' show jiraKeysIn;

/// What Claude gets to write a time entry's description from: the entry, the
/// Jira issue or Trello card it's for (when found) and the notes on earlier
/// entries for the same task.
Map<String, dynamic> entryDescriptionInput({
  required String title,
  String? project,
  int? minutes,
  DateTime? date,
  JiraIssue? issue,
  TrelloCard? card,
  List<String> earlierNotes = const [],
}) {
  String clip(String text, int max) => text.length > max ? '${text.substring(0, max)}…' : text;
  final issueText = issue == null ? '' : (issue.fullDescription.isNotEmpty ? issue.fullDescription : issue.description);
  return {
    'entryTitle': title,
    if (project != null && project.isNotEmpty) 'project': project,
    if (minutes != null && minutes > 0) 'timeSpent': formatMinutes(minutes),
    if (date != null) 'date': dateKey(date),
    if (issue != null)
      'jiraIssue': {
        'key': issue.key,
        'title': issue.summary,
        if (issue.issueType.isNotEmpty) 'type': issue.issueType,
        if (issue.status.isNotEmpty) 'status': issue.status,
        if (issueText.isNotEmpty) 'description': clip(issueText, 1500),
      },
    if (card != null)
      'trelloCard': {
        'title': card.name,
        if (card.listName.isNotEmpty) 'list': card.listName,
        if (card.labels.isNotEmpty) 'labels': [for (final l in card.labels) if (l.name.isNotEmpty) l.name],
        if (card.shortDescription.isNotEmpty) 'description': clip(card.shortDescription, 1500),
      },
    if (earlierNotes.isNotEmpty) 'earlierNotesOnThisTask': earlierNotes,
  };
}

const entryDescriptionInstruction =
    'Write the description for a time entry on a developer\'s timesheet, from the JSON on stdin: the '
    'entry, the Jira issue or Trello card it is for (when known) and notes from earlier entries on the '
    'same task. Say briefly what was done in this time, e.g. "Fixed saving of user-defined windows on '
    'custom tabs". Base it on the task description; if earlier notes show progress, describe the next '
    'logical piece of work rather than repeating them. At most 12 words, one line, no task key, no '
    'title repeated word for word, no quotes, no trailing period. Reply with only the description.';

/// Claude's answer as a one-line description: first line, no quotes, bullet
/// or trailing period, at most [max] characters.
String cleanEntryDescription(String text, {int max = 1000}) {
  var line = text.trim().split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => '').trim();
  line = line.replaceFirst(RegExp(r'^(description:\s*|[-•*]\s*)', caseSensitive: false), '');
  line = line.replaceAll(RegExp(r'^["“”\x27]+|["“”\x27]+$'), '').trim();
  if (line.endsWith('.') && !line.endsWith('..')) line = line.substring(0, line.length - 1);
  return line.length > max ? line.substring(0, max) : line;
}

/// Notes written on earlier [entries] with this [title] (newest first, up
/// to [limit]), or naming its Jira [key].
List<String> earlierNotesFor(List<TimeEntry> entries, String title, {int limit = 4}) {
  String norm(String s) => s.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  final keys = jiraKeysIn(title).toSet();
  final same = [
    for (final e in entries)
      if ((e.description ?? '').trim().isNotEmpty &&
          (norm(e.taskTitle) == norm(title) || jiraKeysIn(e.taskTitle).any(keys.contains)))
        e,
  ]..sort((a, b) {
      final byDate = b.date.compareTo(a.date);
      return byDate != 0 ? byDate : (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0));
    });
  final notes = <String>[];
  for (final e in same) {
    final note = e.description!.trim();
    if (!notes.contains(note)) notes.add(note);
    if (notes.length == limit) break;
  }
  return notes;
}
