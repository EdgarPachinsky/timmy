import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/links.dart';
import '../../models/jira.dart';
import '../../state/jira_controller.dart';
import 'jira_rich_text.dart';
import 'jira_status_menu.dart';
import 'jira_task_list.dart';

/// Opens the Jira tasks page. Pushed routes sit above the signed-in
/// providers, so the Jira controller is handed over explicitly.
Future<void> openJiraTasks(BuildContext context) {
  final jira = context.read<JiraController>();
  return Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => ChangeNotifierProvider.value(value: jira, child: const JiraTasksPage()),
  ));
}

/// Browse, filter and search your Jira tasks; click one to read it in full
/// and move it to another column.
class JiraTasksPage extends StatefulWidget {
  const JiraTasksPage({super.key});

  @override
  State<JiraTasksPage> createState() => _JiraTasksPageState();
}

class _JiraTasksPageState extends State<JiraTasksPage> {
  final _list = GlobalKey<JiraTaskListState>();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final jira = context.watch<JiraController>();
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 44,
        titleSpacing: 0,
        centerTitle: false,
        title: Text('Jira tasks', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            iconSize: 18,
            icon: const Icon(Icons.refresh),
            onPressed: () => _list.currentState?.refresh(),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: jira.isConnected
          ? JiraTaskList(
              key: _list,
              jira: jira,
              onSelected: (issue) => showJiraIssueDetails(
                context,
                jira,
                issue,
                onMoved: () => _list.currentState?.refresh(),
              ),
            )
          : const Center(child: Text('Jira is not connected.')),
    );
  }
}

/// The whole task: key, type, priority, status (click to move it to another
/// column), title and the full description with clickable links.
Future<void> showJiraIssueDetails(
  BuildContext context,
  JiraController jira,
  JiraIssue issue, {
  VoidCallback? onMoved,
}) =>
    showDialog<void>(
      context: context,
      builder: (context) => _IssueDetails(jira: jira, issue: issue, onMoved: onMoved),
    );

class _IssueDetails extends StatefulWidget {
  const _IssueDetails({required this.jira, required this.issue, this.onMoved});

  final JiraController jira;
  final JiraIssue issue;
  final VoidCallback? onMoved;

  @override
  State<_IssueDetails> createState() => _IssueDetailsState();
}

class _IssueDetailsState extends State<_IssueDetails> {
  late String _status = widget.issue.status;
  late String _category = widget.issue.statusCategory;
  bool _moving = false;

  Future<void> _changeStatus(BuildContext anchor) async {
    setState(() => _moving = true);
    // The menu needs the status as it is now, which may differ from the list's.
    final current = JiraIssue(key: widget.issue.key, summary: widget.issue.summary, status: _status);
    final moved = await moveJiraIssue(
      context,
      widget.jira,
      current,
      position: menuPositionBelow(anchor),
    );
    if (!mounted) return;
    setState(() {
      _moving = false;
      if (moved != null) {
        _status = moved.toStatus;
        _category = moved.toCategory;
      }
    });
    if (moved != null) widget.onMoved?.call();
  }

  Future<void> _openInJira() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final url = widget.jira.browseUrl(widget.issue.key);
    if (url == null || !await openExternal(url.toString())) {
      messenger?.showSnackBar(const SnackBar(content: Text("Couldn't open Jira.")));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final issue = widget.issue;
    final myAccountId = widget.jira.accountId;
    final assignedAt = issue.assigneeAccountId != null && issue.assigneeAccountId == myAccountId
        ? issue.assignedAt
        : null;
    final details = [
      if (issue.projectName.isNotEmpty) issue.projectName,
      if (issue.issueType.isNotEmpty) issue.issueType,
    ].join(' · ');
    final runs = issue.descriptionRuns.isNotEmpty
        ? issue.descriptionRuns
        : [if (issue.description.isNotEmpty) JiraTextRun(issue.description)];

    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 680),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 4, 4),
              child: Row(
                children: [
                  JiraTypeIcon(type: issue.issueType),
                  const SizedBox(width: 6),
                  Text(
                    issue.key,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (issue.priority.isNotEmpty) ...[
                    const SizedBox(width: 10),
                    JiraPriority(name: issue.priority),
                  ],
                  const Spacer(),
                  IconButton(
                    tooltip: 'Open in Jira',
                    iconSize: 18,
                    icon: const Icon(Icons.open_in_new),
                    onPressed: _openInJira,
                  ),
                  IconButton(
                    tooltip: 'Close',
                    iconSize: 18,
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
                child: SelectionArea(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        issue.summary.isEmpty ? '(no title)' : issue.summary,
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 10,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Builder(
                            builder: (anchor) => _StatusButton(
                              status: _status.isEmpty ? 'No status' : _status,
                              color: jiraStatusColor(_category, scheme),
                              busy: _moving,
                              onPressed: _moving ? null : () => _changeStatus(anchor),
                            ),
                          ),
                          if (assignedAt != null) JiraAssignedAge(since: assignedAt),
                          if (details.isNotEmpty)
                            Text(details, style: theme.textTheme.labelSmall?.copyWith(color: muted)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Divider(height: 1, color: scheme.outlineVariant),
                      const SizedBox(height: 12),
                      Text(
                        'Description',
                        style: theme.textTheme.labelMedium?.copyWith(color: muted, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 6),
                      if (runs.isEmpty)
                        Text(
                          'No description.',
                          style: theme.textTheme.bodyMedium?.copyWith(color: muted, fontStyle: FontStyle.italic),
                        )
                      else
                        JiraRichDescription(
                          runs: runs,
                          style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The current column as a pill; clicking it lists where the task can go.
class _StatusButton extends StatelessWidget {
  const _StatusButton({
    required this.status,
    required this.color,
    required this.busy,
    required this.onPressed,
  });

  final String status;
  final Color color;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Tooltip(
      message: 'Move to another column',
      child: Material(
        color: color.withValues(alpha: 0.14),
        shape: StadiumBorder(side: BorderSide(color: color.withValues(alpha: 0.5))),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 6, 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Text(status, style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(width: 2),
                if (busy)
                  const Padding(
                    padding: EdgeInsets.all(3),
                    child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                else
                  Icon(Icons.arrow_drop_down, size: 18, color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
