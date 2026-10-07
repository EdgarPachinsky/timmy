import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../state/auth_controller.dart';
import '../../state/workspaces_controller.dart';
import '../../widgets/common.dart';
import '../shell/user_menu.dart';

class WorkspacesScreen extends StatelessWidget {
  const WorkspacesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<WorkspacesController>();
    final user = context.watch<AuthController>().user;
    final workspaces = controller.workspaces;

    Widget body;
    if (workspaces == null) {
      body = controller.error != null
          ? ErrorState(message: controller.error!, onRetry: controller.load)
          : const Center(child: CircularProgressIndicator());
    } else if (workspaces.isEmpty) {
      body = const EmptyState(
        icon: Icons.workspaces_outline,
        message: "You aren't a member of any workspace yet.",
      );
    } else {
      body = ListView.separated(
        shrinkWrap: true,
        itemCount: workspaces.length,
        separatorBuilder: (_, _) => const SizedBox(height: 6),
        itemBuilder: (context, i) => _WorkspaceCard(
          workspace: workspaces[i],
          onTap: () => controller.select(workspaces[i]),
        ),
      );
    }

    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 44,
        titleSpacing: 12,
        centerTitle: false,
        title: Text('Timmy', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            iconSize: 18,
            onPressed: controller.loading ? null : controller.load,
            icon: const Icon(Icons.refresh),
          ),
          if (user != null) UserMenu(user: user),
          const SizedBox(width: 10),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Choose a workspace',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
                Text(
                  user == null ? '' : 'Signed in as ${user.name}',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                Flexible(child: body),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _WorkspaceCard extends StatelessWidget {
  const _WorkspaceCard({required this.workspace, required this.onTap});

  final Workspace workspace;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
          child: Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: scheme.primaryContainer,
                child: Text(
                  workspace.name.isEmpty ? '?' : workspace.name[0].toUpperCase(),
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
                            workspace.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(workspace.myRole, style: theme.textTheme.labelSmall),
                        ),
                      ],
                    ),
                    Text(
                      '${workspace.memberCount} members · ${workspace.projectCount} projects · ${workspace.timezone}',
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
