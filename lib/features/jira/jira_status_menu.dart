import 'package:flutter/material.dart';

import '../../core/jira_client.dart';
import '../../models/jira.dart';
import '../../state/jira_controller.dart';
import 'jira_task_list.dart';

/// A menu position just below [context]'s widget.
RelativeRect menuPositionBelow(BuildContext context) {
  final box = context.findRenderObject()! as RenderBox;
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final topLeft = box.localToGlobal(Offset(0, box.size.height), ancestor: overlay);
  return RelativeRect.fromRect(topLeft & const Size(1, 1), Offset.zero & overlay.size);
}

/// A menu position at [globalPosition], e.g. where the user right-clicked.
RelativeRect menuPositionAt(BuildContext context, Offset globalPosition) {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final local = overlay.globalToLocal(globalPosition);
  return RelativeRect.fromRect(local & const Size(1, 1), Offset.zero & overlay.size);
}

/// Moves [issue] to another column, as on the Jira board: asks Jira which
/// statuses its workflow allows next, shows them in a menu at [position], and
/// applies the choice. Returns the transition taken, or null.
Future<JiraTransition?> moveJiraIssue(
  BuildContext context,
  JiraController jira,
  JiraIssue issue, {
  required RelativeRect position,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  void say(String message) => messenger?.showSnackBar(SnackBar(content: Text(message)));

  List<JiraTransition> transitions;
  try {
    transitions = await jira.transitionsFor(issue.key);
  } on JiraException catch (e) {
    say("Couldn't load statuses for ${issue.key}: ${e.message}");
    return null;
  }
  if (!context.mounted) return null;
  final options = [for (final t in transitions) if (t.toStatus != issue.status) t];
  if (options.isEmpty) {
    say('${issue.key} has nowhere else to move from "${issue.status}".');
    return null;
  }

  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  final picked = await showMenu<JiraTransition>(
    context: context,
    position: position,
    items: [
      PopupMenuItem(
        enabled: false,
        height: 28,
        child: Text(
          'Move ${issue.key} to',
          style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ),
      for (final t in options)
        PopupMenuItem(
          value: t,
          height: 36,
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: jiraStatusColor(t.toCategory, scheme),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              Flexible(child: Text(t.toStatus, overflow: TextOverflow.ellipsis)),
              // Some workflows name the move differently from the column.
              if (t.name.isNotEmpty && t.name != t.toStatus)
                Flexible(
                  child: Text(
                    '  ${t.name}',
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
            ],
          ),
        ),
    ],
  );
  if (picked == null) return null;

  try {
    await jira.moveIssue(issue.key, picked);
  } on JiraException catch (e) {
    say("Couldn't move ${issue.key}: ${e.message}");
    return null;
  }
  say('Moved ${issue.key} to ${picked.toStatus}.');
  return picked;
}
