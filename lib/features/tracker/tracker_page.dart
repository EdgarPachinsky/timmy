import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../models/models.dart';
import '../../state/jira_controller.dart';
import '../../state/tracker_controller.dart';
import '../../state/trello_controller.dart';
import '../../state/workspace_session.dart';
import '../../widgets/common.dart';
import '../entries/entry_editor.dart';
import '../jira/jira_status_menu.dart';
import '../settings/settings_page.dart';
import '../tasks/task_picker.dart';
import 'elapsed_text.dart';
import 'tracker_logic.dart';

class TrackerPage extends StatefulWidget {
  const TrackerPage({super.key});

  @override
  State<TrackerPage> createState() => _TrackerPageState();
}

class _TrackerPageState extends State<TrackerPage> {
  /// Replaced (see [_clearValidation]) to start the form's checks afresh.
  var _formKey = GlobalKey<FormState>();

  /// Forgets the form's validation state (red fields, "touched" flags)
  /// without touching its values, by rebuilding the form under a new key.
  /// (FormState.reset would instead restore the text from the last build.)
  void _clearValidation() => setState(() => _formKey = GlobalKey<FormState>());
  late final TextEditingController _title;
  late final TextEditingController _description;
  String? _startProblem;

  late final TrackerController _tracker;
  late int _seenExternalEdits;

  /// The planner (or another screen) filled the form: show its text.
  void _onTrackerChanged() {
    if (_tracker.externalEdits == _seenExternalEdits) return;
    _seenExternalEdits = _tracker.externalEdits;
    _syncTextFromController(_tracker);
    if (!mounted) return;
    _clearValidation();
    setState(() => _startProblem = null);
  }

  @override
  void initState() {
    super.initState();
    final tracker = context.read<TrackerController>();
    _tracker = tracker;
    _seenExternalEdits = tracker.externalEdits;
    tracker.addListener(_onTrackerChanged);
    _title = TextEditingController(text: tracker.taskTitle);
    _description = TextEditingController(text: tracker.description);
    // Entries left over from a previous run (offline, crash) are retried now.
    if (tracker.pending.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => tracker.flushPending());
    }
  }

  @override
  void dispose() {
    _tracker.removeListener(_onTrackerChanged);
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  /// The controller clears the form after an entry is saved; mirror that.
  void _syncTextFromController(TrackerController tracker) {
    _title.text = tracker.taskTitle;
    _description.text = tracker.description;
  }

  void _start(TrackerController tracker) {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _startProblem = tracker.start());
  }

  /// Whether the End menu stopped a running timer, so closing the menu
  /// without a choice (or a choice that can't go through) restarts it.
  bool _resumeAfterEnd = false;

  /// Pressing End stops the clock while the user picks where the time goes.
  void _onEndMenuOpened(TrackerController tracker) {
    _resumeAfterEnd = tracker.isRunning;
    tracker.pause();
  }

  void _onEndMenuClosed(TrackerController tracker) {
    // A pick runs in the same event as the close; let it claim the timer first.
    scheduleMicrotask(() {
      if (!_resumeAfterEnd) return;
      _resumeAfterEnd = false;
      tracker.resume();
    });
  }

  /// "45s" under a minute, otherwise "1h 30m".
  static String _durationLabel(Duration elapsed) =>
      elapsed.inSeconds < 60 ? '${elapsed.inSeconds}s' : formatMinutes(roundToMinutes(elapsed));

  /// Ends the timer, uploading to Time-Wise or, with [upload] false, keeping
  /// the entry on this Mac.
  Future<void> _end(TrackerController tracker, {required bool upload}) async {
    final resume = _resumeAfterEnd;
    _resumeAfterEnd = false;
    void keepTiming() {
      if (resume) tracker.resume();
    }

    if (!_formKey.currentState!.validate()) {
      keepTiming();
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final minutes = roundToMinutes(tracker.elapsed);
    final duration = _durationLabel(tracker.elapsed);
    final project = tracker.projectName;

    final outcome = await tracker.end(upload: upload);
    if (outcome == EndOutcome.invalid || outcome == EndOutcome.tooShort) keepTiming();
    if (!mounted) return;
    _syncTextFromController(tracker);
    if (outcome != EndOutcome.invalid && outcome != EndOutcome.tooShort) {
      // The entry is done and the form is empty for the next one: clear the
      // validation from this End so the blank title doesn't show as an error.
      _clearValidation();
    }
    switch (outcome) {
      case EndOutcome.saved:
        messenger.showSnackBar(SnackBar(
          content: Text('Saved ${formatMinutes(minutes)} to $project'),
        ));
      case EndOutcome.keptLocally:
        messenger.showSnackBar(SnackBar(
          content: Text('Kept $duration on this Mac. Upload it from Entries.'),
        ));
      case EndOutcome.tooShort:
        messenger.showSnackBar(const SnackBar(
          content: Text('Time-Wise needs at least a minute. Choose "Keep on this Mac" to save it locally.'),
        ));
      case EndOutcome.invalid:
        messenger.showSnackBar(SnackBar(content: Text(tracker.invalidReason ?? 'Check the form.')));
      case EndOutcome.failed:
        break; // The banner at the top explains and offers a retry.
    }
  }

  /// Fills the title (and maybe description) from a Jira task or Trello
  /// card. With nothing connected it opens Settings first.
  Future<void> _pickTask(TrackerController tracker, RelativeRect position) async {
    final jira = context.read<JiraController>();
    final trello = context.read<TrelloController>();
    if (!hasTaskSource(jira, trello)) {
      await openSettings(context);
      if (!mounted || !hasTaskSource(jira, trello)) return;
    }
    final task = await pickTask(context, jira: jira, trello: trello, position: position);
    if (task == null || !mounted) return;

    final title = task.title.length > 500 ? task.title.substring(0, 500) : task.title;
    _title.text = title;
    tracker.setTaskTitle(title);
    final description = task.description;
    if (description != null && _description.text.trim().isEmpty) {
      final text = description.length > 1000 ? description.substring(0, 1000) : description;
      _description.text = text;
      tracker.setDescription(text);
    }
    setState(() => _startProblem = null);
  }

  /// End menu → Stop without saving. The menu paused the timer; it runs on
  /// again if the user keeps it.
  void _stopWithoutSaving(TrackerController tracker) {
    final resume = _resumeAfterEnd;
    _resumeAfterEnd = false;
    _confirmDiscard(tracker, resumeIfKept: resume);
  }

  Future<void> _confirmDiscard(TrackerController tracker, {bool resumeIfKept = false}) async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard this timer?'),
        content: Text(
          'The ${formatClock(tracker.elapsed)} tracked so far will be lost and nothing will be saved.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep tracking')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (discard == true) {
      tracker.discard();
      setState(() => _startProblem = null);
    } else if (resumeIfKept) {
      tracker.resume();
    }
  }

  @override
  Widget build(BuildContext context) {
    final tracker = context.watch<TrackerController>();

    // The timer stays pinned so Start/Pause/End are always in reach; only the
    // form scrolls beneath it.
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (tracker.pending.isNotEmpty) ...[
                    _PendingBanner(tracker: tracker),
                    const SizedBox(height: 8),
                  ],
                  _TimerCard(
                    tracker: tracker,
                    problem: _startProblem,
                    onStart: () => _start(tracker),
                    onPause: tracker.pause,
                    onResume: tracker.resume,
                    onEnd: (upload) => _end(tracker, upload: upload),
                    onEndMenuOpened: () => _onEndMenuOpened(tracker),
                    onEndMenuClosed: () => _onEndMenuClosed(tracker),
                    onDiscard: () => _confirmDiscard(tracker),
                    onStopWithoutSaving: () => _stopWithoutSaving(tracker),
                    onAddTime: context.watch<WorkspaceSession>().trackableProjects.isEmpty
                        ? null
                        : () => addTimeManually(context),
                  ),
                ],
              ),
            ),
            // A fixed card filling the rest of the window: the page doesn't
            // scroll; only the tags inside it would, if there were many.
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                child: Form(
                  key: _formKey,
                  child: _DetailsCard(
                    tracker: tracker,
                    title: _title,
                    description: _description,
                    onChanged: () => setState(() => _startProblem = null),
                    onPickTask: (position) => _pickTask(tracker, position),
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

// ---------------------------------------------------------------------------

class _PendingBanner extends StatelessWidget {
  const _PendingBanner({required this.tracker});

  final TrackerController tracker;

  @override
  Widget build(BuildContext context) {
    final pending = tracker.pending;
    final total = pending.fold<int>(0, (sum, p) => sum + p.minutes);
    final what = pending.length == 1
        ? '${formatMinutes(total)} on "${pending.first.taskTitle}"'
        : '${pending.length} entries (${formatMinutes(total)})';

    final String message;
    if (tracker.saving) {
      message = 'Saving $what…';
    } else if (tracker.saveError != null) {
      message = "Couldn't save $what: ${tracker.saveError}";
    } else {
      message = '$what still to be saved.';
    }

    return InlineNotice(
      icon: tracker.saving ? Icons.cloud_upload_outlined : Icons.warning_amber_rounded,
      isError: tracker.saveError != null,
      message: message,
      trailing: tracker.saving
          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
          : null,
      actions: tracker.saving
          ? const []
          : [
              TextButton(onPressed: tracker.flushPending, child: const Text('Retry')),
              TextButton(
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Discard unsaved time?'),
                      content: Text('$what will be deleted permanently.'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Discard'),
                        ),
                      ],
                    ),
                  );
                  if (ok == true) tracker.discardPending();
                },
                child: const Text('Discard'),
              ),
            ],
    );
  }
}

// ---------------------------------------------------------------------------

class _TimerCard extends StatelessWidget {
  const _TimerCard({
    required this.tracker,
    required this.problem,
    required this.onStart,
    required this.onPause,
    required this.onResume,
    required this.onEnd,
    required this.onEndMenuOpened,
    required this.onEndMenuClosed,
    required this.onDiscard,
    required this.onStopWithoutSaving,
    required this.onAddTime,
  });

  final TrackerController tracker;
  final String? problem;
  final VoidCallback onStart;
  final VoidCallback onPause;
  final VoidCallback onResume;
  /// Ends the timer; `true` uploads to Time-Wise, `false` keeps it locally.
  final ValueChanged<bool> onEnd;
  final VoidCallback onEndMenuOpened;
  final VoidCallback onEndMenuClosed;
  final VoidCallback onDiscard;

  /// End menu → Stop without saving.
  final VoidCallback onStopWithoutSaving;

  /// Opens "Add time" (time by hand, no timer); null while it can't.
  final VoidCallback? onAddTime;

  /// The clock row never changes height, whatever the status text or the
  /// buttons beside it (big clock + two status lines, one with the pill).
  static const _rowHeight = 74.0;

  String _status() {
    final started = tracker.startedAt;
    if (started == null) return 'Ready. Fill in the details, then press Start.';
    final day = formatDay(started);
    final when = switch (day) {
      'Today' => 'today',
      'Yesterday' => 'yesterday',
      _ => day,
    };
    final since = '$when at ${formatTimeOfDay(started)}';
    return tracker.isRunning ? 'Tracking since $since' : 'Paused · started $since';
  }

  /// Round icon controls (named by their tooltips) to keep the card small.
  List<Widget> _buttons(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final running = tracker.isRunning;
    final big = IconButton.styleFrom(
      minimumSize: const Size.square(44),
      visualDensity: VisualDensity.standard,
    );
    if (!tracker.isActive) {
      return [
        IconButton.filled(
          tooltip: 'Start',
          onPressed: onStart,
          style: big,
          iconSize: 28,
          icon: const Icon(Icons.play_arrow_rounded),
        ),
      ];
    }
    return [
      IconButton(
        tooltip: 'Discard',
        onPressed: onDiscard,
        color: scheme.error,
        iconSize: 20,
        icon: const Icon(Icons.delete_outline),
      ),
      IconButton.filledTonal(
        tooltip: running ? 'Pause' : 'Resume',
        onPressed: running ? onPause : onResume,
        icon: Icon(running ? Icons.pause_rounded : Icons.play_arrow_rounded),
      ),
      _EndButton(
        style: big,
        enabled: !tracker.saving,
        onEnd: onEnd,
        onStopWithoutSaving: onStopWithoutSaving,
        onOpen: onEndMenuOpened,
        onClose: onEndMenuClosed,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final buttons = _buttons(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: _rowHeight),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: ElapsedText(
                            controller: tracker,
                            style: theme.textTheme.displaySmall!.copyWith(
                              fontSize: 34,
                              height: 1.15,
                              fontWeight: FontWeight.w300,
                              color: tracker.isRunning ? scheme.primary : scheme.onSurface,
                            ),
                          ),
                        ),
                        // "Add time" sits right after the status, in its flow.
                        Text.rich(
                          TextSpan(children: [
                            TextSpan(text: '${_status()} '),
                            WidgetSpan(
                              alignment: PlaceholderAlignment.middle,
                              // Nudged down a touch to sit on the text's line.
                              child: Transform.translate(
                                offset: const Offset(0, 2),
                                child: Tooltip(
                                  message: 'Add time manually, without the timer',
                                  // A small tinted pill, so it reads as a button.
                                  child: FilledButton.tonalIcon(
                                    onPressed: onAddTime,
                                    style: FilledButton.styleFrom(
                                      minimumSize: const Size(0, 18),
                                      padding: const EdgeInsets.fromLTRB(6, 0, 8, 0),
                                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                      visualDensity: VisualDensity.compact,
                                      shape: const StadiumBorder(),
                                      textStyle: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600),
                                    ),
                                    icon: const Icon(Icons.add, size: 12),
                                    label: const Text('Add manually'),
                                  ),
                                ),
                              ),
                            ),
                          ]),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  for (var i = 0; i < buttons.length; i++) ...[
                    if (i > 0) const SizedBox(width: 4),
                    buttons[i],
                  ],
                ],
              ),
            ),
            if (problem != null) ...[
              const SizedBox(height: 6),
              Text(problem!, style: theme.textTheme.bodySmall?.copyWith(color: scheme.error)),
            ],
          ],
        ),
      ),
    );
  }
}

/// The stop button. It opens a small menu: upload to Time-Wise now, keep the
/// entry on this Mac to upload later from Entries, or stop without saving.
class _EndButton extends StatelessWidget {
  const _EndButton({
    required this.style,
    required this.enabled,
    required this.onEnd,
    required this.onStopWithoutSaving,
    required this.onOpen,
    required this.onClose,
  });

  final ButtonStyle style;
  final bool enabled;
  final ValueChanged<bool> onEnd;
  final VoidCallback onStopWithoutSaving;

  /// The menu opened (the timer is stopped while choosing) / closed.
  final VoidCallback onOpen;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final danger = theme.colorScheme.error;

    Widget option(String title, String subtitle, {Color? color}) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: color)),
            Text(subtitle, style: theme.textTheme.labelSmall?.copyWith(color: muted)),
          ],
        );

    return MenuAnchor(
      alignmentOffset: const Offset(-150, 4),
      onOpen: onOpen,
      onClose: onClose,
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(Icons.cloud_upload_outlined, size: 20),
          onPressed: () => onEnd(true),
          child: option('Save to Time-Wise', 'Upload now'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.laptop_mac_outlined, size: 20),
          onPressed: () => onEnd(false),
          child: option('Keep on this Mac', 'Upload later from Entries'),
        ),
        const Divider(height: 9),
        MenuItemButton(
          leadingIcon: Icon(Icons.delete_outline, size: 20, color: danger),
          onPressed: onStopWithoutSaving,
          child: option('Stop without saving', 'Clear the timer, nothing is saved', color: danger),
        ),
      ],
      builder: (context, menu, _) => IconButton.filled(
        tooltip: 'End',
        onPressed: enabled ? () => menu.isOpen ? menu.close() : menu.open() : null,
        style: style,
        iconSize: 26,
        icon: const Icon(Icons.stop_rounded),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _DetailsCard extends StatelessWidget {
  const _DetailsCard({
    required this.tracker,
    required this.title,
    required this.description,
    required this.onChanged,
    required this.onPickTask,
  });

  final TrackerController tracker;
  final TextEditingController title;
  final TextEditingController description;
  final VoidCallback onChanged;
  /// Pick a Jira task or Trello card; the menu (if any) opens at the position.
  final ValueChanged<RelativeRect> onPickTask;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = context.watch<WorkspaceSession>();
    final pickTooltip = pickTaskTooltip(context.watch<JiraController>(), context.watch<TrelloController>());
    final projects = session.trackableProjects;
    final selectedProject = projects.any((p) => p.id == tracker.projectId) ? tracker.projectId : null;

    const gap = SizedBox(height: 10);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<int>(
              // initialValue only applies on creation; re-key so changes made
              // elsewhere (e.g. "Track" on the Projects page) are reflected.
              key: ValueKey(selectedProject),
              initialValue: selectedProject,
              isExpanded: true,
              isDense: true,
              decoration: _fieldDecoration('Project', Icons.folder_outlined).copyWith(
                helperMaxLines: 2,
                helperText: session.projects.loading && session.projects.data == null
                    ? 'Loading projects…'
                    : projects.isEmpty && !session.projects.loading && session.projects.error == null
                        ? 'No active projects are assigned to you in this workspace.'
                        : null,
              ),
              hint: const Text('Select a project'),
              items: [
                for (final p in projects)
                  DropdownMenuItem(value: p.id, child: _ProjectLabel(project: p)),
              ],
              selectedItemBuilder: (context) => [
                for (final p in projects) Align(alignment: Alignment.centerLeft, child: _ProjectLabel(project: p)),
              ],
              validator: (value) => value == null ? 'Select a project' : null,
              onChanged: (id) {
                if (id == null) return;
                tracker.setProject(projects.firstWhere((p) => p.id == id));
                onChanged();
              },
            ),
            if (session.projects.error != null) ...[
              const SizedBox(height: 4),
              _LoadError(message: session.projects.error!, onRetry: session.loadProjects),
            ],
            gap,
            TextFormField(
              controller: title,
              maxLength: 500,
              decoration: _fieldDecoration('Task title', Icons.task_alt_outlined).copyWith(
                counterText: '',
                suffixIcon: Builder(
                  builder: (anchor) => IconButton(
                    tooltip: pickTooltip,
                    iconSize: 18,
                    icon: const Icon(Icons.manage_search),
                    onPressed: () => onPickTask(menuPositionBelow(anchor)),
                  ),
                ),
                suffixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 34),
              ),
              textInputAction: TextInputAction.next,
              autovalidateMode: AutovalidateMode.onUserInteraction,
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter a task title' : null,
              onChanged: (v) {
                tracker.setTaskTitle(v);
                onChanged();
              },
            ),
            gap,
            TextFormField(
              controller: description,
              maxLength: 1000,
              minLines: 1,
              maxLines: 3,
              decoration: _fieldDecoration('Description (optional)', Icons.notes).copyWith(counterText: ''),
              onChanged: tracker.setDescription,
            ),
            gap,
            _WhenRow(tracker: tracker, onChanged: onChanged),
            const SizedBox(height: 10),
            Text(
              'Tags',
              style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: SingleChildScrollView(
                child: _TagPicker(tracker: tracker, session: session),
              ),
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              contentPadding: EdgeInsets.zero,
              title: const Text('Billable'),
              value: tracker.billable,
              onChanged: tracker.setBillable,
            ),
          ],
        ),
      ),
    );
  }
}

/// Dense field decoration with a small leading icon.
InputDecoration _fieldDecoration(String label, IconData icon) => InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon, size: 18),
      prefixIconConstraints: const BoxConstraints(minWidth: 38, minHeight: 36),
    );

class _ProjectLabel extends StatelessWidget {
  const _ProjectLabel({required this.project});

  final Project project;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final client = project.client?.fullName;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ColorDot(project.color, size: 8),
        const SizedBox(width: 8),
        Flexible(child: Text(project.name, overflow: TextOverflow.ellipsis)),
        if (client != null && client.isNotEmpty) ...[
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              client,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: muted, fontSize: 12),
            ),
          ),
        ],
      ],
    );
  }
}

/// Date and start-time pickers. Both are locked once the timer is running,
/// where they show the actual start instead.
class _WhenRow extends StatelessWidget {
  const _WhenRow({required this.tracker, required this.onChanged});

  final TrackerController tracker;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final active = tracker.isActive;
    final started = tracker.startedAt;
    final l10n = MaterialLocalizations.of(context);
    final today = dateOnly(DateTime.now());

    final dateText = active && started != null
        ? formatDay(started)
        : tracker.date == null
            ? 'Today'
            : formatDay(tracker.date!);
    final timeText = active && started != null
        ? formatTimeOfDay(started)
        : tracker.startTime == null
            ? 'Now'
            : l10n.formatTimeOfDay(tracker.startTime!, alwaysUse24HourFormat: true);

    return Row(
      children: [
        Expanded(
          child: _PickerField(
            label: 'Date',
            value: dateText,
            icon: Icons.calendar_today_outlined,
            enabled: !active,
            onClear: tracker.date == null ? null : () => tracker.setDate(null),
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: tracker.date ?? today,
                firstDate: today.subtract(const Duration(days: 365)),
                lastDate: today,
              );
              if (picked != null) {
                tracker.setDate(picked);
                onChanged();
              }
            },
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _PickerField(
            label: 'Start time',
            value: timeText,
            icon: Icons.schedule,
            enabled: !active,
            onClear: tracker.startTime == null ? null : () => tracker.setStartTime(null),
            onTap: () async {
              final picked = await showTimePicker(
                context: context,
                initialTime: tracker.startTime ?? TimeOfDay.now(),
                initialEntryMode: TimePickerEntryMode.input,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
                  child: child!,
                ),
              );
              if (picked != null) {
                tracker.setStartTime(picked);
                onChanged();
              }
            },
          ),
        ),
      ],
    );
  }
}

class _PickerField extends StatelessWidget {
  const _PickerField({
    required this.label,
    required this.value,
    required this.icon,
    required this.onTap,
    required this.enabled,
    this.onClear,
  });

  final String label;
  final String value;
  final IconData icon;
  final VoidCallback onTap;
  final bool enabled;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: enabled ? onTap : null,
      child: InputDecorator(
        isEmpty: false,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon, size: 16),
          prefixIconConstraints: const BoxConstraints(minWidth: 34, minHeight: 34),
          enabled: enabled,
          suffixIcon: enabled && onClear != null
              ? IconButton(
                  tooltip: label == 'Date' ? 'Reset to today' : 'Reset to now',
                  iconSize: 16,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(width: 28, height: 28),
                  icon: const Icon(Icons.close),
                  onPressed: onClear,
                )
              : null,
          suffixIconConstraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        ),
        child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

class _TagPicker extends StatelessWidget {
  const _TagPicker({required this.tracker, required this.session});

  final TrackerController tracker;
  final WorkspaceSession session;

  @override
  Widget build(BuildContext context) {
    final tags = session.tags;
    if (tags.data == null) {
      return tags.error != null
          ? _LoadError(message: tags.error!, onRetry: session.loadTags)
          : const Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            );
    }
    if (tags.data!.isEmpty) {
      return Text(
        'This workspace has no tags yet.',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      );
    }
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final tag in tags.data!)
          FilterChip(
            visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: const EdgeInsets.symmetric(horizontal: 2),
            labelPadding: const EdgeInsets.only(left: 2, right: 4),
            labelStyle: Theme.of(context).textTheme.labelSmall,
            avatar: ColorDot(tag.color, size: 6),
            label: Text(tag.name),
            selected: tracker.tagIds.contains(tag.id),
            showCheckmark: false,
            onSelected: (_) => tracker.toggleTag(tag.id),
          ),
      ],
    );
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    return Row(
      children: [
        Icon(Icons.error_outline, size: 16, color: error),
        const SizedBox(width: 6),
        Expanded(child: Text(message, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: error))),
        TextButton(onPressed: onRetry, child: const Text('Retry')),
      ],
    );
  }
}
