import 'package:flutter/foundation.dart';

import '../core/api_client.dart';
import '../core/storage.dart';
import '../models/models.dart';

/// Loads the user's workspaces and tracks which one is open. The last-opened
/// workspace is reopened automatically on the next launch.
class WorkspacesController extends ChangeNotifier {
  WorkspacesController(this._api, this._storage);

  final ApiClient _api;
  final AppStorage _storage;

  List<Workspace>? _workspaces;
  Workspace? _selected;
  bool _loading = false;
  String? _error;

  List<Workspace>? get workspaces => _workspaces;
  Workspace? get selected => _selected;
  bool get loading => _loading;
  String? get error => _error;

  Future<void> load() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final list = await _api.workspaces();
      _workspaces = list;
      final savedId = _storage.selectedWorkspaceId;
      if (_selected == null && savedId != null) {
        for (final w in list) {
          if (w.id == savedId) _selected = w;
        }
      }
    } on ApiException catch (e) {
      _error = e.message;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> select(Workspace workspace) async {
    _selected = workspace;
    notifyListeners();
    await _storage.saveSelectedWorkspace(workspace.id);
  }

  /// Back to the workspace list.
  Future<void> clearSelection() async {
    _selected = null;
    notifyListeners();
    await _storage.saveSelectedWorkspace(null);
  }
}
