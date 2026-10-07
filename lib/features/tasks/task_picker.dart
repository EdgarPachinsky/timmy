import 'package:flutter/material.dart';

import '../../state/jira_controller.dart';
import '../../state/trello_controller.dart';
import '../jira/jira_task_picker.dart';
import '../settings/settings_page.dart';
import '../trello/trello_cards_page.dart';

/// What picking a task puts in the form.
class PickedTask {
  const PickedTask({required this.title, this.description});

  final String title;

  /// Set only when the source has something for it (e.g. Jira "key only"
  /// format, or a Trello card link).
  final String? description;
}

/// Whether any task source is connected.
bool hasTaskSource(JiraController jira, TrelloController trello) => jira.isConnected || trello.isConnected;

/// Tooltip for the "pick a task" button.
String pickTaskTooltip(JiraController jira, TrelloController trello) => switch ((jira.isConnected, trello.isConnected)) {
      (true, true) => 'Pick a Jira task or Trello card',
      (true, false) => 'Pick a Jira task',
      (false, true) => 'Pick a Trello card',
      (false, false) => 'Connect Jira or Trello to pick tasks',
    };

/// Lets the user pick a task from the connected sources: straight into the
/// picker when only one is connected, otherwise via a small menu at
/// [position]. Resolves to null when cancelled or nothing is connected.
///
/// Controllers are passed in because dialogs sit above the providers.
Future<PickedTask?> pickTask(
  BuildContext context, {
  required JiraController jira,
  required TrelloController trello,
  required RelativeRect position,
}) async {
  final sources = [
    if (jira.isConnected) Connector.jira,
    if (trello.isConnected) Connector.trello,
  ];
  if (sources.isEmpty) return null;

  final source = sources.length == 1
      ? sources.single
      : await showMenu<Connector>(
          context: context,
          position: position,
          items: [
            for (final s in sources)
              PopupMenuItem(
                value: s,
                height: 40,
                child: Row(
                  children: [
                    ConnectorBadge(connector: s, size: 22),
                    const SizedBox(width: 10),
                    Text(s == Connector.jira ? 'Jira tasks' : 'Trello cards'),
                  ],
                ),
              ),
          ],
        );
  if (source == null || !context.mounted) return null;

  switch (source) {
    case Connector.jira:
      final issue = await showJiraTaskPicker(context, jira);
      if (issue == null) return null;
      final task = jira.taskFor(issue);
      return PickedTask(title: task.title, description: task.description);
    case Connector.trello:
      final card = await showTrelloCardPicker(context, trello);
      if (card == null) return null;
      final task = trello.taskFor(card);
      return PickedTask(title: task.title, description: task.description);
    case Connector.claude:
      return null;
  }
}
