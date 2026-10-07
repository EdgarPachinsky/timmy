import 'package:flutter/material.dart';

import '../../models/jira.dart';
import '../../state/jira_controller.dart';
import 'jira_task_list.dart';

/// Searchable list of Jira tasks grouped by status; resolves to the one
/// picked, or null.
Future<JiraIssue?> showJiraTaskPicker(BuildContext context, JiraController jira) =>
    showDialog<JiraIssue>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(12),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640),
          child: JiraTaskList(
            jira: jira,
            title: 'Jira tasks',
            trailing: IconButton(
              tooltip: 'Close',
              iconSize: 18,
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.pop(context),
            ),
            onSelected: (issue) => Navigator.pop(context, issue),
          ),
        ),
      ),
    );
