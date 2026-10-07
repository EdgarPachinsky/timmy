import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';

/// Everything the app keeps on disk: the session, the chosen workspace, and
/// per-workspace timer state (so a running timer survives restarts).
class AppStorage {
  AppStorage(this._prefs);

  final SharedPreferences _prefs;

  static const _tokenKey = 'auth.token';
  static const _userKey = 'auth.user';
  static const _workspaceKey = 'workspace.selectedId';

  String? get token => _prefs.getString(_tokenKey);
  Future<void> saveToken(String token) => _prefs.setString(_tokenKey, token);

  User? get user {
    final raw = _prefs.getString(_userKey);
    if (raw == null) return null;
    try {
      return User.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveUser(User user) =>
      _prefs.setString(_userKey, jsonEncode(user.toJson()));

  Future<void> clearSession() async {
    await _prefs.remove(_tokenKey);
    await _prefs.remove(_userKey);
    await _prefs.remove(_workspaceKey);
  }

  int? get selectedWorkspaceId => _prefs.getInt(_workspaceKey);

  Future<void> saveSelectedWorkspace(int? id) => id == null
      ? _prefs.remove(_workspaceKey)
      : _prefs.setInt(_workspaceKey, id);

  static String _trackerKey(int userId, int workspaceId) =>
      'tracker.v1.$userId.$workspaceId';

  Map<String, dynamic>? trackerState(int userId, int workspaceId) {
    final raw = _prefs.getString(_trackerKey(userId, workspaceId));
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveTrackerState(
    int userId,
    int workspaceId,
    Map<String, dynamic> state,
  ) =>
      _prefs.setString(_trackerKey(userId, workspaceId), jsonEncode(state));
}
