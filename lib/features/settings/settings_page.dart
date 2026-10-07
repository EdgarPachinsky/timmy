import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/claude_controller.dart';
import '../../state/jira_controller.dart';
import '../../state/trello_controller.dart';
import 'claude_connector_page.dart';
import 'trello_connector_page.dart';
import 'jira_connector_page.dart';

/// Opens Settings. Pushed routes sit above the signed-in providers, so the
/// Jira and Trello controllers are handed over explicitly.
Future<void> openSettings(BuildContext context) {
  final jira = context.read<JiraController>();
  final trello = context.read<TrelloController>();
  return Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: jira),
        ChangeNotifierProvider.value(value: trello),
      ],
      child: const SettingsPage(),
    ),
  ));
}

/// Tools Timmy can pull tasks from.
enum Connector {
  jira(
    name: 'Jira',
    blurb: 'Pick issues as task titles',
    icon: Icons.view_kanban_rounded,
    colors: [Color(0xFF2684FF), Color(0xFF0052CC)],
  ),
  trello(
    name: 'Trello',
    blurb: 'Pick cards as task titles',
    icon: Icons.dashboard_outlined,
    colors: [Color(0xFF2A8BD2), Color(0xFF026AA7)],
  ),
  claude(
    name: 'Claude',
    blurb: 'Plans your day and writes standups',
    icon: Icons.auto_awesome,
    colors: [Color(0xFFE39A7C), Color(0xFFC15F3C)],
  );

  const Connector({required this.name, required this.blurb, required this.icon, required this.colors});

  final String name;
  final String blurb;
  final IconData icon;

  /// Badge gradient, top to bottom.
  final List<Color> colors;
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final jira = context.watch<JiraController>();
    final trello = context.watch<TrelloController>();
    final claude = context.watch<ClaudeController>();
    final connected = [jira.isConnected, trello.isConnected, claude.isConnected].where((c) => c).length;
    final claudeAccount = claude.account;

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 44,
        titleSpacing: 0,
        centerTitle: false,
        title: Text('Settings', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
        children: [
          _SectionHeader(
            icon: Icons.hub_outlined,
            title: 'Connectors',
            subtitle: 'Bring tasks in from the tools you work in.',
            trailing: '$connected of ${Connector.values.length} connected',
          ),
          const SizedBox(height: 8),
          _ConnectorTile(
            connector: Connector.jira,
            connected: jira.isConnected,
            detail: jira.isConnected
                ? '${jira.account?.displayName ?? jira.credentials!.email} · ${jira.credentials!.host}'
                : null,
            onTap: () => openJiraConnector(context),
          ),
          const SizedBox(height: 8),
          _ConnectorTile(
            connector: Connector.trello,
            connected: trello.isConnected,
            detail: trello.isConnected
                ? [
                    trello.member?.fullName ?? 'Trello',
                    if ((trello.member?.username ?? '').isNotEmpty) '@${trello.member!.username}',
                  ].join(' · ')
                : null,
            onTap: () => openTrelloConnector(context),
          ),
          const SizedBox(height: 8),
          _ConnectorTile(
            connector: Connector.claude,
            connected: claude.isConnected,
            detail: claude.isConnected
                ? [
                    claudeAccount?.email ?? 'Claude Code',
                    if (claudeAccount?.plan != null) claudeAccount!.plan!,
                  ].join(' · ')
                : null,
            onTap: () => openClaudeConnector(context),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 8, 2, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 16, color: scheme.onPrimaryContainer),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    Text(
                      trailing,
                      style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectorTile extends StatelessWidget {
  const _ConnectorTile({
    required this.connector,
    required this.connected,
    required this.onTap,
    this.detail,
  });

  final Connector connector;
  final bool connected;
  final VoidCallback onTap;

  /// Who is connected; replaces the blurb when set.
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 6, 10),
          child: Row(
            children: [
              ConnectorBadge(connector: connector),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          connector.name,
                          style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(width: 6),
                        ConnectionPill(connected: connected),
                      ],
                    ),
                    Text(
                      detail ?? connector.blurb,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

/// Rounded gradient tile with the connector's icon.
class ConnectorBadge extends StatelessWidget {
  const ConnectorBadge({super.key, required this.connector, this.size = 36});

  final Connector connector;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.28),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: connector.colors,
        ),
        boxShadow: [
          BoxShadow(
            color: connector.colors.last.withValues(alpha: 0.35),
            blurRadius: size * 0.25,
            offset: Offset(0, size * 0.08),
          ),
        ],
      ),
      child: Icon(connector.icon, size: size * 0.55, color: Colors.white),
    );
  }
}

/// "Connected" with a green dot, or a muted "Not connected".
class ConnectionPill extends StatelessWidget {
  const ConnectionPill({super.key, required this.connected});

  final bool connected;

  static const _green = Color(0xFF22A06B);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = connected ? _green : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: connected ? _green.withValues(alpha: 0.14) : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: fg, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          Text(
            connected ? 'Connected' : 'Not connected',
            style: theme.textTheme.labelSmall?.copyWith(color: fg, fontSize: 10),
          ),
        ],
      ),
    );
  }
}
