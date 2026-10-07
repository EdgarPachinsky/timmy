import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../models/models.dart';
import '../../state/workspace_session.dart';
import '../../widgets/common.dart';

class ProjectsPage extends StatefulWidget {
  const ProjectsPage({super.key, required this.onTrack});

  /// Called when the user wants to track time against a project.
  final ValueChanged<Project> onTrack;

  @override
  State<ProjectsPage> createState() => _ProjectsPageState();
}

class _ProjectsPageState extends State<ProjectsPage> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final session = context.watch<WorkspaceSession>();
    final projects = session.projects;

    final filtered = [
      for (final p in projects.data ?? const <Project>[])
        if (_query.isEmpty ||
            p.name.toLowerCase().contains(_query) ||
            (p.client?.fullName.toLowerCase().contains(_query) ?? false))
          p,
    ]..sort((a, b) {
        // Active projects first, then alphabetical.
        if (a.isActive != b.isActive) return a.isActive ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

    Widget body;
    if (projects.data == null) {
      body = projects.error != null
          ? ErrorState(message: projects.error!, onRetry: session.loadProjects)
          : const Center(child: CircularProgressIndicator());
    } else if (filtered.isEmpty) {
      body = EmptyState(
        icon: Icons.folder_off_outlined,
        message: _query.isEmpty ? 'No projects assigned to you yet.' : 'No projects match "$_query".',
      );
    } else {
      body = ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        itemCount: filtered.length,
        separatorBuilder: (_, _) => const SizedBox(height: 6),
        itemBuilder: (context, i) => _ProjectTile(
          project: filtered[i],
          onTrack: () => widget.onTrack(filtered[i]),
        ),
      );
    }

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 6, 0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      decoration: const InputDecoration(
                        hintText: 'Search projects or clients',
                        prefixIcon: Icon(Icons.search, size: 18),
                        prefixIconConstraints: BoxConstraints(minWidth: 36, minHeight: 34),
                      ),
                      onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh',
                    iconSize: 18,
                    onPressed: projects.loading ? null : session.loadProjects,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
            ),
            if (projects.data != null && projects.error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: InlineNotice(
                  message: "Couldn't refresh: ${projects.error}",
                  icon: Icons.error_outline,
                  isError: true,
                  actions: [TextButton(onPressed: session.loadProjects, child: const Text('Retry'))],
                ),
              ),
            const SizedBox(height: 10),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}

class _ProjectTile extends StatelessWidget {
  const _ProjectTile({required this.project, required this.onTrack});

  final Project project;
  final VoidCallback onTrack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final client = project.client?.fullName;
    final details = [
      if (client != null && client.isNotEmpty) client,
      '${project.memberCount} members',
      '${formatMinutes(project.totalMinutes)} tracked',
    ].join(' · ');

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        child: Row(
          children: [
            ColorDot(project.color, size: 10),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          project.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (!project.isActive) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(project.status, style: theme.textTheme.labelSmall),
                        ),
                      ],
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
            IconButton(
              tooltip: 'Track',
              color: scheme.primary,
              onPressed: project.isActive ? onTrack : null,
              icon: const Icon(Icons.play_circle_outline),
            ),
          ],
        ),
      ),
    );
  }
}
