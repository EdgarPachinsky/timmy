import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/clock.dart';
import '../../core/storage.dart';
import '../../models/models.dart';
import '../../state/auth_controller.dart';
import '../../state/tracker_controller.dart';
import '../../state/workspace_session.dart';
import '../../state/workspaces_controller.dart';
import '../entries/entries_page.dart';
import '../projects/projects_page.dart';
import '../tracker/elapsed_text.dart';
import '../tracker/tracker_page.dart';
import 'user_menu.dart';

/// The signed-in app for one workspace: a compact top bar, tabs, and the three pages.
class WorkspaceShell extends StatelessWidget {
  const WorkspaceShell({super.key, required this.workspace});

  final Workspace workspace;

  @override
  Widget build(BuildContext context) {
    final user = context.read<AuthController>().user!;
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (c) => WorkspaceSession(
            api: c.read<ApiClient>(),
            workspace: workspace,
            user: user,
          )..loadAll(),
        ),
        ChangeNotifierProvider(
          create: (c) {
            final session = c.read<WorkspaceSession>();
            return TrackerController(
              api: c.read<ApiClient>(),
              storage: c.read<AppStorage>(),
              user: user,
              workspace: workspace,
              onEntrySaved: session.loadEntries,
              now: c.read<Clock>(),
            );
          },
        ),
      ],
      child: _ShellScaffold(workspace: workspace, user: user),
    );
  }
}

class _ShellScaffold extends StatefulWidget {
  const _ShellScaffold({required this.workspace, required this.user});

  final Workspace workspace;
  final User user;

  @override
  State<_ShellScaffold> createState() => _ShellScaffoldState();
}

class _ShellScaffoldState extends State<_ShellScaffold> {
  static const _trackerIndex = 0;
  int _index = _trackerIndex;

  void _trackProject(Project project) {
    final tracker = context.read<TrackerController>();
    if (tracker.isActive) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Finish the running timer before switching projects.'),
      ));
    } else {
      tracker.setProject(project);
    }
    setState(() => _index = _trackerIndex);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tracker = context.watch<TrackerController>();

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TopBar(
            workspace: widget.workspace,
            user: widget.user,
            canSwitch: !tracker.isActive,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: _Tabs(
              index: _index,
              onSelected: (i) => setState(() => _index = i),
            ),
          ),
          // The big clock is already on screen in the tracker tab.
          if (tracker.isActive && _index != _trackerIndex)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: _MiniTimer(
                tracker: tracker,
                onTap: () => setState(() => _index = _trackerIndex),
              ),
            ),
          Divider(height: 1, color: scheme.outlineVariant),
          Expanded(
            // IndexedStack keeps each page's state (e.g. half-typed form text).
            child: IndexedStack(
              index: _index,
              children: [
                const TrackerPage(),
                ProjectsPage(onTrack: _trackProject),
                const EntriesPage(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Workspace name and timezone, the switch button, and the account menu.
class _TopBar extends StatelessWidget {
  const _TopBar({required this.workspace, required this.user, required this.canSwitch});

  final Workspace workspace;
  final User user;
  final bool canSwitch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: scheme.primaryContainer,
            child: Text(
              workspace.name.isEmpty ? '?' : workspace.name[0].toUpperCase(),
              style: TextStyle(
                fontSize: 12,
                color: scheme.onPrimaryContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  workspace.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                Text(
                  workspace.timezone,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: canSwitch ? 'Switch workspace' : 'End the running timer to switch workspace',
            iconSize: 18,
            icon: const Icon(Icons.swap_horiz),
            onPressed: canSwitch ? () => context.read<WorkspacesController>().clearSelection() : null,
          ),
          const SizedBox(width: 4),
          UserMenu(user: user),
        ],
      ),
    );
  }
}

/// Segmented tab strip for the three pages.
class _Tabs extends StatelessWidget {
  const _Tabs({required this.index, required this.onSelected});

  final int index;
  final ValueChanged<int> onSelected;

  static const _items = [
    (Icons.timer_outlined, Icons.timer, 'Tracker'),
    (Icons.folder_outlined, Icons.folder, 'Projects'),
    (Icons.list_alt_outlined, Icons.list_alt, 'Entries'),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          for (var i = 0; i < _items.length; i++)
            Expanded(
              child: _Tab(
                icon: i == index ? _items[i].$2 : _items[i].$1,
                label: _items[i].$3,
                selected: i == index,
                onTap: () => onSelected(i),
              ),
            ),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? scheme.surface : Colors.transparent,
        elevation: selected ? 1 : 0,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: SizedBox(
            height: 30,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 16, color: fg),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: fg,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Running-timer strip shown on the other tabs; tapping it opens the tracker.
class _MiniTimer extends StatelessWidget {
  const _MiniTimer({required this.tracker, required this.onTap});

  final TrackerController tracker;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.primaryContainer,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            children: [
              Icon(
                tracker.isRunning ? Icons.fiber_manual_record : Icons.pause_circle_filled,
                size: 12,
                color: tracker.isRunning ? scheme.error : scheme.onPrimaryContainer,
              ),
              const SizedBox(width: 8),
              ElapsedText(
                controller: tracker,
                style: theme.textTheme.titleSmall!.copyWith(
                  fontWeight: FontWeight.w700,
                  color: scheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  tracker.projectName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onPrimaryContainer),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
