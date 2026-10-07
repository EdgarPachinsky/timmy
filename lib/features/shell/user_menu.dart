import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../state/auth_controller.dart';
import '../../state/jira_controller.dart';
import '../../state/trello_controller.dart';
import '../jira/jira_tasks_page.dart';
import '../trello/trello_cards_page.dart';

/// Avatar that opens a menu with the account email and a sign-out action.
class UserMenu extends StatelessWidget {
  const UserMenu({super.key, required this.user});

  final User user;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<String>(
      tooltip: user.email,
      offset: const Offset(0, 36),
      onSelected: (value) {
        switch (value) {
          case 'jira':
            openJiraTasks(context);
          case 'trello':
            openTrelloCards(context);
          case 'logout':
            context.read<AuthController>().logout();
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          enabled: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(user.name, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(user.email, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        const PopupMenuDivider(),
        // Only once Jira is connected (Settings → Connectors → Jira).
        if (context.read<JiraController>().isConnected)
          const PopupMenuItem(
            value: 'jira',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.view_kanban_outlined),
              title: Text('Jira tasks'),
            ),
          ),
        if (context.read<TrelloController>().isConnected)
          const PopupMenuItem(
            value: 'trello',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.dashboard_outlined),
              title: Text('Trello cards'),
            ),
          ),
        const PopupMenuItem(
          value: 'logout',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.logout),
            title: Text('Sign out'),
          ),
        ),
      ],
      child: CircleAvatar(
        radius: 14,
        backgroundColor: scheme.primaryContainer,
        child: Text(
          user.initials,
          style: TextStyle(fontSize: 11, color: scheme.onPrimaryContainer, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
