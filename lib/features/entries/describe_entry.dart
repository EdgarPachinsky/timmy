import 'dart:convert';

import '../../core/entry_description.dart';
import '../../core/planner.dart' show jiraKeysIn;
import '../../models/jira.dart';
import '../../models/models.dart';
import '../../models/trello.dart';
import '../../state/claude_controller.dart';
import '../../state/jira_controller.dart';
import '../../state/trello_controller.dart';

/// Asks Claude for a very short "what was done" for a time entry titled
/// [title]: from the Jira issue the title names (or the Trello card it
/// matches), notes on earlier [entries] for the same task, the project and
/// the time. Returns the cleaned line, empty if Claude suggested nothing.
/// Throws ClaudeException when Claude can't answer.
Future<String> describeEntryWithClaude({
  required ClaudeController claude,
  required JiraController jira,
  required TrelloController trello,
  required List<TimeEntry> entries,
  required String title,
  String? project,
  int? minutes,
  DateTime? date,
}) async {
  JiraIssue? issue;
  final key = jiraKeysIn(title).firstOrNull;
  if (key != null && jira.isConnected) {
    try {
      issue = (await jira.issuesByKeys([key])).firstOrNull;
    } catch (_) {
      // Without the issue, the title and notes still help.
    }
  }
  TrelloCard? card;
  if (issue == null && trello.isConnected) {
    String norm(String s) => s.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
    final wanted = norm(title);
    try {
      card = (await trello.findCards('')).where((c) {
        final name = norm(c.name);
        return name.length >= 4 && (wanted == name || wanted.contains(name));
      }).firstOrNull;
    } catch (_) {
      // No card then; the title and notes still help.
    }
  }
  final answer = await claude.ask(
    kind: 'entry description',
    instruction: entryDescriptionInstruction,
    input: const JsonEncoder.withIndent('  ').convert(entryDescriptionInput(
      title: title,
      project: project,
      minutes: minutes,
      date: date,
      issue: issue,
      card: card,
      earlierNotes: earlierNotesFor(entries, title),
    )),
  );
  return cleanEntryDescription(answer.text);
}
