import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/links.dart';
import '../../state/claude_controller.dart';
import '../../widgets/common.dart';
import 'settings_page.dart';

/// Opens the Claude connector page. The controller is app-wide, so pushed
/// routes can read it directly.
Future<void> openClaudeConnector(BuildContext context) => Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ClaudeConnectorPage()),
    );

const _installGuide = 'https://code.claude.com/docs/en/setup';

class ClaudeConnectorPage extends StatefulWidget {
  const ClaudeConnectorPage({super.key});

  @override
  State<ClaudeConnectorPage> createState() => _ClaudeConnectorPageState();
}

class _ClaudeConnectorPageState extends State<ClaudeConnectorPage> {
  @override
  void initState() {
    super.initState();
    // Refresh who is logged in each time the page opens (after the first
    // frame: the check notifies listeners, which can't happen mid-build).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final claude = context.read<ClaudeController>();
      if (claude.enabled && !claude.busy) claude.check();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final claude = context.watch<ClaudeController>();
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 44,
        titleSpacing: 0,
        centerTitle: false,
        title: Text('Claude', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
        children: [
          _Header(connected: claude.isConnected),
          const SizedBox(height: 14),
          const _SectionTitle('Account'),
          _AccountCard(claude: claude),
          if (claude.error != null) ...[
            const SizedBox(height: 8),
            InlineNotice(message: claude.error!, icon: Icons.error_outline, isError: true),
          ],
          const SizedBox(height: 14),
          const _SectionTitle('Usage by Timmy'),
          _UsageCard(claude: claude),
          const SizedBox(height: 14),
          const _SectionTitle('Settings'),
          _SettingsCard(claude: claude),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.connected});

  final bool connected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 8, 2, 0),
      child: Row(
        children: [
          const ConnectorBadge(connector: Connector.claude, size: 48),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Claude Code',
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(width: 8),
                    ConnectionPill(connected: connected),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  'Uses Claude Code on this Mac, with its login, to plan your day and write standups.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 6),
      child: Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Install / login state, who is logged in, and the buttons to change it.
class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.claude});

  final ClaudeController claude;

  Future<bool> _confirm(BuildContext context, String title, String body, String action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
        ],
      ),
    );
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;

    Widget body;
    switch (claude.status) {
      case ClaudeStatus.unknown:
        body = _Message(
          icon: Icons.power_outlined,
          text: 'Connect to let Timmy use Claude Code on this Mac.',
          actions: [FilledButton(onPressed: claude.connect, child: const Text('Connect'))],
        );
      case ClaudeStatus.checking:
        body = const _Message(icon: Icons.search, text: 'Looking for Claude Code…', loading: true);
      case ClaudeStatus.notInstalled:
        body = _Message(
          icon: Icons.download_outlined,
          text: "Claude Code isn't installed on this Mac (no `claude` command found). Install it, "
              'log in once, then check again.',
          actions: [
            TextButton(onPressed: () => openExternal(_installGuide), child: const Text('How to install')),
            FilledButton(onPressed: claude.connect, child: const Text('Check again')),
          ],
        );
      case ClaudeStatus.loggedOut:
        body = claude.waitingForLogin
            ? const _Message(
                icon: Icons.open_in_new,
                text: 'Finish logging in in the Terminal window (it opens your browser). '
                    'Timmy picks it up automatically.',
                loading: true,
              )
            : _Message(
                icon: Icons.login,
                text: 'Claude Code is installed but nobody is logged in.',
                actions: [
                  FilledButton.icon(
                    onPressed: claude.busy ? null : claude.login,
                    icon: const Icon(Icons.login, size: 18),
                    label: const Text('Log in'),
                  ),
                ],
              );
      case ClaudeStatus.error:
        body = _Message(
          icon: Icons.error_outline,
          text: "Couldn't check Claude Code.",
          actions: [FilledButton(onPressed: claude.connect, child: const Text('Try again'))],
        );
      case ClaudeStatus.loggedIn:
        final account = claude.account;
        final name = account?.email ?? 'Logged in';
        final details = [
          if (account?.organization != null) account!.organization!,
          if (account?.plan != null) _capitalize(account!.plan!),
          if (account?.authMethod != null) _authLabel(account!.authMethod!),
        ].join(' · ');
        body = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: const Color(0xFFC15F3C).withValues(alpha: 0.18),
                  child: Text(
                    name.isEmpty ? '?' : name[0].toUpperCase(),
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: const Color(0xFFC15F3C),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      if (details.isNotEmpty)
                        Text(
                          details,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(color: muted),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              alignment: WrapAlignment.end,
              children: [
                if (claude.enabled)
                  TextButton(onPressed: claude.disconnect, child: const Text('Disconnect from Timmy'))
                else
                  FilledButton(onPressed: claude.connect, child: const Text('Use in Timmy')),
                OutlinedButton(
                  onPressed: claude.busy
                      ? null
                      : () async {
                          if (await _confirm(
                            context,
                            'Switch Claude account?',
                            'This logs Claude Code out on this Mac (Terminal included), then opens a '
                                'Terminal window to log in with another account.',
                            'Switch',
                          )) {
                            await claude.switchAccount();
                          }
                        },
                  child: const Text('Switch account'),
                ),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: scheme.error),
                  onPressed: claude.busy
                      ? null
                      : () async {
                          if (await _confirm(
                            context,
                            'Log out of Claude Code?',
                            'This logs Claude Code out on this whole Mac, including in Terminal. '
                                'To only stop Timmy using it, choose Disconnect from Timmy instead.',
                            'Log out',
                          )) {
                            await claude.logout();
                          }
                        },
                  child: const Text('Log out'),
                ),
              ],
            ),
          ],
        );
    }

    return Card(child: Padding(padding: const EdgeInsets.all(12), child: body));
  }

  static String _capitalize(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  static String _authLabel(String method) => switch (method) {
        'claude.ai' => 'Claude subscription',
        'api_key' || 'api_key_helper' => 'API key',
        'oauth_token' => 'Token',
        'third_party' => 'Cloud provider',
        _ => method,
      };
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.actions = const [], this.loading = false});

  final IconData icon;
  final String text;
  final List<Widget> actions;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (loading)
              const Padding(
                padding: EdgeInsets.all(2),
                child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else
              Icon(icon, size: 20, color: muted),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
          ],
        ),
        if (actions.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(alignment: WrapAlignment.end, spacing: 6, runSpacing: 4, children: actions),
        ],
      ],
    );
  }
}

/// What Timmy's own requests used, today and this month.
class _UsageCard extends StatelessWidget {
  const _UsageCard({required this.claude});

  final ClaudeController claude;

  static String _tokens(int n) => n >= 1000000
      ? '${(n / 1000000).toStringAsFixed(1)}M'
      : n >= 1000
          ? '${(n / 1000).toStringAsFixed(1)}k'
          : '$n';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;

    Widget row(String label, ClaudeUsageSummary s) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              SizedBox(
                width: 78,
                child: Text(label, style: theme.textTheme.labelMedium?.copyWith(color: muted)),
              ),
              Expanded(
                child: Text(
                  '${s.requests} ${s.requests == 1 ? 'request' : 'requests'} · '
                  '${_tokens(s.inputTokens + s.outputTokens)} tokens',
                  style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                '~\$${s.costUsd.toStringAsFixed(2)}',
                style: theme.textTheme.labelMedium?.copyWith(color: muted),
              ),
            ],
          ),
        );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            row('Today', claude.usageToday),
            row('This month', claude.usageThisMonth),
            const SizedBox(height: 6),
            Text(
              'Costs are Claude Code\'s estimates at API prices. With a Claude subscription, '
              'requests count toward your plan\'s limits instead; run /usage in Claude Code to see them.',
              style: theme.textTheme.labelSmall?.copyWith(color: muted),
            ),
          ],
        ),
      ),
    );
  }
}

/// Model choice and where the `claude` command is.
class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.claude});

  final ClaudeController claude;

  Future<void> _editPath(BuildContext context) async {
    final controller = TextEditingController(text: claude.preferredPath.isEmpty ? (claude.path ?? '') : claude.preferredPath);
    final path = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Claude Code location'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '/Users/you/.local/bin/claude',
            helperText: 'Run `which claude` in Terminal to find it. Leave empty to search.',
            helperMaxLines: 2,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (path != null) await claude.setPreferredPath(path);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Model', style: theme.textTheme.labelMedium),
            const SizedBox(height: 6),
            SegmentedButton<String>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const [
                ButtonSegment(value: '', label: Text('Default')),
                ButtonSegment(value: 'haiku', label: Text('Haiku')),
                ButtonSegment(value: 'sonnet', label: Text('Sonnet')),
                ButtonSegment(value: 'opus', label: Text('Opus')),
              ],
              selected: {claude.model},
              onSelectionChanged: (s) => claude.setModel(s.first),
            ),
            const SizedBox(height: 4),
            Text(
              'Haiku is quickest and lightest on your limits; Default uses your Claude Code setting.',
              style: theme.textTheme.labelSmall?.copyWith(color: muted),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Claude Code location', style: theme.textTheme.labelMedium),
                      Text(
                        [claude.path ?? 'Not found yet', if (claude.version != null) claude.version!].join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(color: muted),
                      ),
                    ],
                  ),
                ),
                TextButton(onPressed: () => _editPath(context), child: const Text('Change')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
