import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/links.dart';
import '../../core/trello_client.dart';
import '../../models/trello.dart';
import '../../state/trello_controller.dart';
import '../../widgets/common.dart';
import 'settings_page.dart';

/// Opens the Trello connector page. Pushed routes sit above the signed-in
/// providers, so the Trello controller is handed over explicitly.
Future<void> openTrelloConnector(BuildContext context) {
  final trello = context.read<TrelloController>();
  return Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => ChangeNotifierProvider.value(value: trello, child: const TrelloConnectorPage()),
  ));
}

class TrelloConnectorPage extends StatelessWidget {
  const TrelloConnectorPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final trello = context.watch<TrelloController>();
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 44,
        titleSpacing: 0,
        centerTitle: false,
        title: Text('Trello', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
        children: [
          _Header(connected: trello.isConnected),
          const SizedBox(height: 14),
          if (trello.isConnected) ...[
            const _SectionTitle('Account'),
            _AccountCard(trello: trello),
            const SizedBox(height: 14),
            const _SectionTitle('Cards'),
            _CardSettings(trello: trello),
          ] else ...[
            const _SectionTitle('Connect'),
            const _ConnectForm(),
          ],
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
          const ConnectorBadge(connector: Connector.trello, size: 48),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('Trello', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(width: 8),
                    ConnectionPill(connected: connected),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  'Pick Trello cards as task titles, and browse them by board and list.',
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

/// Key, then token (from Trello's authorize page), then Connect.
class _ConnectForm extends StatefulWidget {
  const _ConnectForm();

  @override
  State<_ConnectForm> createState() => _ConnectFormState();
}

class _ConnectFormState extends State<_ConnectForm> {
  final _key = TextEditingController();
  final _token = TextEditingController();
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _key.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _getToken() async {
    if (_key.text.trim().isEmpty) {
      setState(() => _error = 'Paste your API key first; the token is made for it.');
      return;
    }
    setState(() => _error = null);
    if (!await openExternal(trelloAuthorizeUrl(_key.text).toString()) && mounted) {
      setState(() => _error = "Couldn't open the browser.");
    }
  }

  Future<void> _connect() async {
    final trello = context.read<TrelloController>();
    if (trello.connecting) return;
    setState(() => _error = null);
    try {
      await trello.connect(apiKey: _key.text, token: _token.text);
    } on TrelloException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final connecting = context.watch<TrelloController>().connecting;

    Widget step(String number, String text) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 18,
                child: Text(number, style: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700)),
              ),
              Expanded(child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: muted))),
            ],
          ),
        );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            step('1.', 'Create a Power-Up in Trello\'s admin page (any name), open its API key tab and copy the key.'),
            step('2.', 'Paste the key below and press Get token. Allow Timmy in the browser and copy the token.'),
            step('3.', 'Paste the token and press Connect.'),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => openExternal(trelloApiKeyPage),
                icon: const Icon(Icons.open_in_new, size: 14),
                label: const Text('Open Trello\'s Power-Up admin'),
              ),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _key,
              enabled: !connecting,
              decoration: _decoration('API key', Icons.vpn_key_outlined),
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: connecting ? null : _getToken,
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Get token'),
              ),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _token,
              enabled: !connecting,
              obscureText: _obscure,
              onSubmitted: (_) => _connect(),
              decoration: _decoration('Token', Icons.key_outlined).copyWith(
                suffixIcon: IconButton(
                  tooltip: _obscure ? 'Show token' : 'Hide token',
                  iconSize: 18,
                  icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              InlineNotice(message: _error!, icon: Icons.error_outline, isError: true),
            ],
            const SizedBox(height: 12),
            FilledButton(
              onPressed: connecting ? null : _connect,
              child: connecting
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.5))
                  : const Text('Connect Trello'),
            ),
          ],
        ),
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.trello});

  final TrelloController trello;

  Future<void> _confirmDisconnect(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Disconnect Trello?'),
        content: const Text('Timmy will forget your Trello token. You can connect again any time.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Disconnect')),
        ],
      ),
    );
    if (ok == true) await trello.disconnect();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final member = trello.member;
    final name = (member?.fullName ?? '').isNotEmpty ? member!.fullName : 'Trello account';
    final details = [
      if ((member?.username ?? '').isNotEmpty) '@${member!.username}',
      if (member?.email != null) member!.email!,
    ].join(' · ');
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: const Color(0xFF026AA7).withValues(alpha: 0.18),
              child: Text(
                name[0].toUpperCase(),
                style: theme.textTheme.titleSmall?.copyWith(
                  color: const Color(0xFF2A8BD2),
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
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                ],
              ),
            ),
            TextButton(
              onPressed: () => _confirmDisconnect(context),
              style: TextButton.styleFrom(foregroundColor: scheme.error),
              child: const Text('Disconnect'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Which cards to list, and what picking one fills in.
class _CardSettings extends StatelessWidget {
  const _CardSettings({required this.trello});

  final TrelloController trello;

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
            Text('Which cards to list', style: theme.textTheme.labelMedium),
            const SizedBox(height: 6),
            SegmentedButton<TrelloCardScope>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const [
                ButtonSegment(value: TrelloCardScope.mine, label: Text('Assigned to me')),
                ButtonSegment(value: TrelloCardScope.allBoards, label: Text('All on my boards')),
              ],
              selected: {trello.scope},
              onSelectionChanged: (s) => trello.setScope(s.first),
            ),
            const SizedBox(height: 4),
            Text(
              trello.scope == TrelloCardScope.mine
                  ? 'Open cards you are a member of, on any board.'
                  : 'Every open card on your open boards (up to ${TrelloClient.maxBoards} boards).',
              style: theme.textTheme.labelSmall?.copyWith(color: muted),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              contentPadding: EdgeInsets.zero,
              title: const Text('Add the card link to the description'),
              subtitle: const Text('When you pick a card; the title is the card name.'),
              value: trello.linkInDescription,
              onChanged: trello.setLinkInDescription,
            ),
          ],
        ),
      ),
    );
  }
}

InputDecoration _decoration(String label, IconData icon) => InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon, size: 18),
      prefixIconConstraints: const BoxConstraints(minWidth: 38, minHeight: 36),
    );
