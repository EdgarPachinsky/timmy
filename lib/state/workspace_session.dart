import 'package:flutter/foundation.dart';

import '../core/api_client.dart';
import '../models/models.dart';

/// A value that is loading, loaded, failed — or loaded with a failed refresh.
class Loadable<T> {
  const Loadable({this.data, this.loading = false, this.error});

  final T? data;
  final bool loading;
  final String? error;
}

/// Server data for the currently open workspace: projects the user can track
/// against, the tag catalogue, and the user's own time entries.
class WorkspaceSession extends ChangeNotifier {
  WorkspaceSession({
    required this._api,
    required this.workspace,
    required this.user,
  });

  final ApiClient _api;
  final Workspace workspace;
  final User user;

  Loadable<List<Project>> projects = const Loadable(loading: true);
  Loadable<List<Tag>> tags = const Loadable(loading: true);
  Loadable<List<TimeEntry>> entries = const Loadable(loading: true);

  bool _disposed = false;

  /// Projects that can receive time (archived ones are hidden from the picker).
  List<Project> get trackableProjects =>
      (projects.data ?? const []).where((p) => p.isActive).toList();

  Future<void> loadAll() => Future.wait([loadProjects(), loadTags(), loadEntries()]);

  Future<void> loadProjects() => _load(
        () => projects,
        (v) => projects = v,
        () => _api.projects(workspace.id, memberId: user.id),
      );

  Future<void> loadTags() => _load(
        () => tags,
        (v) => tags = v,
        () async {
          final list = await _api.tags(workspace.id);
          return list..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        },
      );

  Future<void> loadEntries() => _load(
        () => entries,
        (v) => entries = v,
        () async {
          final list = await _api.timeEntries(workspace.id, userId: user.id);
          // Newest day first; within a day, most recently logged first.
          return list
            ..sort((a, b) {
              final byDate = b.date.compareTo(a.date);
              if (byDate != 0) return byDate;
              return (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0));
            });
        },
      );

  /// Saves changes to one of the user's entries in Time-Wise, then reloads
  /// the list. Throws [ApiException] if the server refuses.
  Future<void> updateEntry(int entryId, Map<String, dynamic> payload) async {
    await _api.updateTimeEntry(workspace.id, entryId, payload);
    await loadEntries();
  }

  /// Deletes one of the user's entries from Time-Wise, then reloads the list.
  /// Throws [ApiException] if the server refuses.
  Future<void> deleteEntry(int entryId) async {
    await _api.deleteTimeEntry(workspace.id, entryId);
    await loadEntries();
  }

  /// Puts a just-deleted entry back (as a new entry with the same fields),
  /// for Undo. Throws [ApiException] if the server refuses.
  Future<void> restoreEntry(TimeEntry entry) async {
    await _api.createTimeEntry(workspace.id, {
      'projectId': entry.projectId,
      'taskTitle': entry.taskTitle,
      'description': entry.description,
      'hours': entry.totalMinutes ~/ 60,
      'minutes': entry.totalMinutes % 60,
      'date': entry.date,
      'billable': entry.billable,
      'tagIds': [for (final t in entry.tags) t.id]..sort(),
    });
    await loadEntries();
  }

  Future<void> _load<T>(
    Loadable<T> Function() get,
    void Function(Loadable<T>) set,
    Future<T> Function() fetch,
  ) async {
    set(Loadable(data: get().data, loading: true));
    notifyListeners();
    try {
      set(Loadable(data: await fetch()));
    } on ApiException catch (e) {
      set(Loadable(data: get().data, error: e.message));
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
