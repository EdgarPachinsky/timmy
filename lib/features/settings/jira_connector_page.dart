import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/jira_client.dart';
import '../../models/jira.dart';
import '../../state/auth_controller.dart';
import '../../state/jira_controller.dart';
import '../../widgets/common.dart';
import 'settings_page.dart';

/// Opens the Jira connector page. Pushed routes sit above the signed-in
/// providers, so the Jira controller is handed over explicitly.
Future<void> openJiraConnector(BuildContext context) {
  final jira = context.read<JiraController>();
  return Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => ChangeNotifierProvider.value(value: jira, child: const JiraConnectorPage()),
  ));
}

class JiraConnectorPage extends StatelessWidget {
  const JiraConnectorPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final jira = context.watch<JiraController>();
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 44,
        titleSpacing: 0,
        centerTitle: false,
        title: Text('Jira', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
        children: [
          _JiraHeader(connected: jira.isConnected),
          const SizedBox(height: 14),
          if (jira.isConnected) ...[
            const _SectionTitle('Account'),
            _JiraAccountCard(jira: jira),
            const SizedBox(height: 14),
            const _SectionTitle('Task list'),
            _JiraListSettings(jira: jira),
          ] else ...[
            const _SectionTitle('Connect'),
            const _JiraConnectForm(),
          ],
        ],
      ),
    );
  }
}

/// Big badge, name and what the connector does.
class _JiraHeader extends StatelessWidget {
  const _JiraHeader({required this.connected});

  final bool connected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 8, 2, 0),
      child: Row(
        children: [
          const ConnectorBadge(connector: Connector.jira, size: 48),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Jira Cloud',
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(width: 8),
                    ConnectionPill(connected: connected),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  'Pick Jira issues as task titles, with their summary and description.',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
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
      padding: const EdgeInsets.fromLTRB(2, 4, 2, 6),
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

class _JiraConnectForm extends StatefulWidget {
  const _JiraConnectForm();

  @override
  State<_JiraConnectForm> createState() => _JiraConnectFormState();
}

class _JiraConnectFormState extends State<_JiraConnectForm> {
  final _formKey = GlobalKey<FormState>();
  final _site = TextEditingController();
  late final TextEditingController _email;
  final _token = TextEditingController();
  bool _obscure = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Most people use the same email for Jira and Time-Wise.
    _email = TextEditingController(text: context.read<AuthController>().user?.email ?? '');
  }

  @override
  void dispose() {
    _site.dispose();
    _email.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final jira = context.read<JiraController>();
    if (jira.connecting || !_formKey.currentState!.validate()) return;
    setState(() => _error = null);
    try {
      await jira.connect(site: _site.text, email: _email.text, apiToken: _token.text);
    } on JiraException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final connecting = context.watch<JiraController>().connecting;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _site,
                enabled: !connecting,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.next,
                decoration: _decoration('Jira site', Icons.language).copyWith(
                  hintText: 'your-team.atlassian.net',
                ),
                validator: (v) => JiraCredentials.normalizeSite(v ?? '') == null
                    ? 'Enter your Jira site'
                    : null,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _email,
                enabled: !connecting,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                decoration: _decoration('Jira email', Icons.mail_outline),
                validator: (v) => (v ?? '').contains('@') ? null : 'Enter the email you use for Jira',
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _token,
                enabled: !connecting,
                obscureText: _obscure,
                onFieldSubmitted: (_) => _connect(),
                decoration: _decoration('API token', Icons.key_outlined).copyWith(
                  helperText: 'Create one at id.atlassian.com → Security → API tokens.',
                  helperMaxLines: 2,
                  suffixIcon: IconButton(
                    tooltip: _obscure ? 'Show token' : 'Hide token',
                    iconSize: 18,
                    icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                validator: (v) => (v ?? '').trim().isEmpty ? 'Paste your API token' : null,
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
                    : const Text('Connect Jira'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _JiraAccountCard extends StatelessWidget {
  const _JiraAccountCard({required this.jira});

  final JiraController jira;

  Future<void> _confirmDisconnect(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Disconnect Jira?'),
        content: const Text('Timmy will forget your API token. You can connect again any time.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Disconnect')),
        ],
      ),
    );
    if (ok == true) await jira.disconnect();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final account = jira.account;
    final name = account?.displayName ?? jira.credentials!.email;
    final details = [
      account?.emailAddress ?? jira.credentials!.email,
      jira.credentials!.host,
    ].join(' · ');

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: scheme.primaryContainer,
              child: Text(
                name.isEmpty ? '?' : name[0].toUpperCase(),
                style: theme.textTheme.titleSmall?.copyWith(
                  color: scheme.onPrimaryContainer,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(Icons.check_circle, size: 14, color: scheme.primary),
                    ],
                  ),
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

/// Which issues the picker lists, and how a picked issue fills the form.
class _JiraListSettings extends StatefulWidget {
  const _JiraListSettings({required this.jira});

  final JiraController jira;

  @override
  State<_JiraListSettings> createState() => _JiraListSettingsState();
}

class _JiraListSettingsState extends State<_JiraListSettings> {
  late final TextEditingController _jql = TextEditingController(text: widget.jira.jql);

  @override
  void dispose() {
    _jql.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final jira = widget.jira;
    final edited = _jql.text.trim() != jira.jql;
    final isDefault = jira.jql == defaultJiraJql && !edited;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _jql,
              minLines: 1,
              maxLines: 3,
              style: theme.textTheme.bodySmall,
              decoration: const InputDecoration(
                labelText: 'Which tasks to list (JQL)',
                helperText: 'Default: open tasks assigned to you. Search and typed keys still work.',
                helperMaxLines: 2,
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (v) => jira.setJql(v),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: isDefault
                      ? null
                      : () {
                          _jql.text = defaultJiraJql;
                          jira.setJql(defaultJiraJql);
                          setState(() {});
                        },
                  child: const Text('Reset'),
                ),
                TextButton(
                  onPressed: edited
                      ? () async {
                          await jira.setJql(_jql.text);
                          _jql.text = jira.jql;
                          if (mounted) setState(() {});
                        }
                      : null,
                  child: const Text('Save'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text('When you pick a task, fill the title with', style: theme.textTheme.labelMedium),
            const SizedBox(height: 6),
            SegmentedButton<JiraTitleFormat>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const [
                ButtonSegment(value: JiraTitleFormat.keyAndSummary, label: Text('Key + title')),
                ButtonSegment(value: JiraTitleFormat.keyOnly, label: Text('Key only')),
              ],
              selected: {jira.titleFormat},
              onSelectionChanged: (s) => jira.setTitleFormat(s.first),
            ),
            const SizedBox(height: 6),
            Text(
              switch (jira.titleFormat) {
                JiraTitleFormat.keyAndSummary => 'e.g. "CDEV-2228 Pay Now Functional"',
                JiraTitleFormat.keyOnly => 'e.g. "CDEV-2228", with the Jira title in the description',
              },
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
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
