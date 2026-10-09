import 'package:flutter/foundation.dart';

import '../core/jira_client.dart';
import '../core/storage.dart';
import '../models/jira.dart';

/// How a picked Jira issue fills in the tracker form.
enum JiraTitleFormat {
  /// Title: `CDEV-2228 Pay Now Functional`.
  keyAndSummary,

  /// Title: `CDEV-2228`; the summary goes into an empty description.
  keyOnly,
}

/// The current user's Jira connection, and the task search the tracker uses.
class JiraController extends ChangeNotifier {
  JiraController({
    required JiraClient client,
    required AppStorage storage,
    required int userId,
  })  : _client = client,
        _storage = storage,
        _userId = userId {
    _load();
  }

  final JiraClient _client;
  final AppStorage _storage;
  final int _userId;

  JiraCredentials? _credentials;
  JiraUser? _account;
  String _jql = defaultJiraJql;
  JiraTitleFormat _titleFormat = JiraTitleFormat.keyAndSummary;
  bool _connecting = false;

  /// The saved list (empty search), reused briefly so typing doesn't refetch it.
  List<JiraIssue>? _listCache;
  DateTime? _listCachedAt;
  static const _listCacheAge = Duration(minutes: 2);

  bool get isConnected => _credentials != null;
  bool get connecting => _connecting;
  JiraCredentials? get credentials => _credentials;
  JiraUser? get account => _account;

  /// The connected Jira account's id, to tell which issues are assigned to you.
  String? get accountId => _account?.accountId;

  /// Which status groups the picker shows open, kept while the app runs.
  final Map<String, bool> pickerExpanded = {};

  /// The saved query for the task list.
  String get jql => _jql;
  JiraTitleFormat get titleFormat => _titleFormat;

  void _load() {
    final saved = _storage.jiraSettings(_userId);
    if (saved == null) return;
    try {
      final creds = saved['credentials'];
      if (creds is Map<String, dynamic>) _credentials = JiraCredentials.fromJson(creds);
      final account = saved['account'];
      if (account is Map<String, dynamic>) _account = JiraUser.fromJson(account);
    } catch (_) {
      _credentials = null;
      _account = null;
    }
    final jql = saved['jql'];
    if (jql is String && jql.trim().isNotEmpty) _jql = jql;
    _titleFormat = JiraTitleFormat.values.firstWhere(
      (f) => f.name == saved['titleFormat'],
      orElse: () => JiraTitleFormat.keyAndSummary,
    );
  }

  Future<void> _save() => _storage.saveJiraSettings(_userId, {
        'credentials': _credentials?.toJson(),
        'account': _account?.toJson(),
        'jql': _jql,
        'titleFormat': _titleFormat.name,
      });

  /// Checks the credentials against Jira and saves them if they work.
  /// Throws [JiraException] with a readable message otherwise.
  Future<void> connect({
    required String site,
    required String email,
    required String apiToken,
  }) async {
    final normalized = JiraCredentials.normalizeSite(site);
    if (normalized == null) {
      throw const JiraException('Enter your Jira site, e.g. your-team.atlassian.net.');
    }
    final credentials = JiraCredentials(
      site: normalized,
      email: email.trim(),
      apiToken: apiToken.trim(),
    );
    _connecting = true;
    notifyListeners();
    try {
      _account = await _client.myself(credentials);
      _credentials = credentials;
      _listCache = null;
      await _save();
    } finally {
      _connecting = false;
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    _credentials = null;
    _account = null;
    _listCache = null;
    notifyListeners();
    await _save();
  }

  Future<void> setJql(String jql) async {
    _jql = jql.trim().isEmpty ? defaultJiraJql : jql.trim();
    _listCache = null;
    notifyListeners();
    await _save();
  }

  Future<void> setTitleFormat(JiraTitleFormat format) async {
    _titleFormat = format;
    notifyListeners();
    await _save();
  }

  /// Issues for the picker; see [buildJiraJql] for how [query] narrows them.
  Future<List<JiraIssue>> search(String query) {
    final credentials = _credentials;
    if (credentials == null) {
      return Future.error(const JiraException('Connect Jira in Settings first.'));
    }
    return _client.search(credentials, jql: buildJiraJql(_jql, query));
  }

  /// Tasks for the picker and the Jira tasks page.
  ///
  /// Empty: the saved list. An issue key: that issue. Otherwise every issue
  /// whose title or description *contains* [query] (any case): Jira's search
  /// only matches whole words, so its word matches are merged with the saved
  /// list and both are filtered here. [refresh] skips the cached list.
  Future<List<JiraIssue>> findTasks(String query, {bool refresh = false}) async {
    final typed = query.trim();
    if (isJiraIssueKey(typed)) return search(typed);

    final cached = _listCache;
    final List<JiraIssue> list;
    if (!refresh &&
        cached != null &&
        DateTime.now().difference(_listCachedAt!) < _listCacheAge) {
      list = cached;
    } else {
      list = await search('');
      _listCache = list;
      _listCachedAt = DateTime.now();
    }
    if (typed.isEmpty) return list;

    List<JiraIssue> words;
    try {
      words = await search(typed);
    } on JiraException {
      words = const []; // Odd input Jira can't search for; local matches still count.
    }
    final seen = <String>{};
    return [
      for (final issue in [...list, ...words])
        if (seen.add(issue.key) && jiraIssueContains(issue, typed)) issue,
    ];
  }

  /// The issues with these [keys], whatever their status or assignee (e.g.
  /// tickets named in your entries that are done by now). Keys Jira doesn't
  /// know are left out.
  Future<List<JiraIssue>> issuesByKeys(Iterable<String> keys) async {
    final credentials = _credentials;
    if (credentials == null) throw const JiraException('Connect Jira in Settings first.');
    final list = {for (final k in keys) k.trim().toUpperCase()}.where(isJiraIssueKey).take(50).toList();
    if (list.isEmpty) return const [];
    try {
      return await _client.search(credentials, jql: 'key in (${list.join(',')})', maxResults: list.length);
    } on JiraException {
      // One unknown key fails the whole query; ask for each on its own.
      final found = await Future.wait([
        for (final key in list)
          _client
              .search(credentials, jql: 'key = $key', maxResults: 1)
              .catchError((Object _) => const <JiraIssue>[]),
      ]);
      return [for (final issues in found) ...issues];
    }
  }

  /// Link to the issue in Jira's web app.
  Uri? browseUrl(String issueKey) {
    final credentials = _credentials;
    return credentials?.baseUri.replace(path: '/browse/$issueKey');
  }

  /// The statuses [issueKey] can move to right now.
  Future<List<JiraTransition>> transitionsFor(String issueKey) {
    final credentials = _credentials;
    if (credentials == null) {
      return Future.error(const JiraException('Connect Jira in Settings first.'));
    }
    return _client.transitions(credentials, issueKey);
  }

  /// Moves [issueKey] to another column, like dragging it on the board.
  Future<void> moveIssue(String issueKey, JiraTransition transition) async {
    final credentials = _credentials;
    if (credentials == null) throw const JiraException('Connect Jira in Settings first.');
    await _client.transition(credentials, issueKey, transition.id);
    _listCache = null; // Its column changed.
  }

  /// Filters for the task lists, kept while the app runs: priority and issue
  /// type names. Empty means no filter.
  final Set<String> priorityFilter = {};
  final Set<String> typeFilter = {};

  /// What picking [issue] puts in the tracker's title and description.
  ({String title, String? description}) taskFor(JiraIssue issue) => switch (_titleFormat) {
        JiraTitleFormat.keyAndSummary => (
            title: [issue.key, issue.summary].where((s) => s.isNotEmpty).join(' '),
            description: null,
          ),
        JiraTitleFormat.keyOnly => (
            title: issue.key,
            description: issue.summary.isEmpty ? null : issue.summary,
          ),
      };
}
