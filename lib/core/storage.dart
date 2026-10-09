import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';

/// Everything the app keeps on disk: the session, the chosen workspace,
/// per-workspace timer state (so a running timer survives restarts) and the
/// Jira connection.
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

  static String _jiraKey(int userId) => 'jira.v1.$userId';

  /// The Jira connection and picker settings for one Timmy user.
  Map<String, dynamic>? jiraSettings(int userId) {
    final raw = _prefs.getString(_jiraKey(userId));
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveJiraSettings(int userId, Map<String, dynamic> settings) =>
      _prefs.setString(_jiraKey(userId), jsonEncode(settings));

  static const _claudeKey = 'claude.v1';

  /// The Claude Code connector: on/off, CLI location, model and usage log.
  /// App-wide: the CLI login belongs to the Mac, not to a Timmy user.
  Map<String, dynamic>? get claudeSettings {
    final raw = _prefs.getString(_claudeKey);
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveClaudeSettings(Map<String, dynamic> settings) =>
      _prefs.setString(_claudeKey, jsonEncode(settings));

  static String _trelloKey(int userId) => 'trello.v1.$userId';

  /// The Trello connection and picker settings for one Timmy user.
  Map<String, dynamic>? trelloSettings(int userId) {
    final raw = _prefs.getString(_trelloKey(userId));
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveTrelloSettings(int userId, Map<String, dynamic> settings) =>
      _prefs.setString(_trelloKey(userId), jsonEncode(settings));

  static String _standupKey(int userId) => 'standup.v1.$userId';

  /// The last standup written for one Timmy user, for the menu bar.
  ({String text, DateTime at})? lastStandup(int userId) {
    final raw = _prefs.getString(_standupKey(userId));
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return (text: json['text'] as String, at: DateTime.parse(json['at'] as String));
    } catch (_) {
      return null;
    }
  }

  Future<void> saveLastStandup(int userId, String text, DateTime at) => _prefs.setString(
      _standupKey(userId), jsonEncode({'text': text, 'at': at.toIso8601String()}));
}
