/// Jira Cloud data used by Timmy: the saved connection, the signed-in Jira
/// account, and the issues offered as task titles.
library;

/// The tasks listed by default: open issues assigned to you, newest first.
const defaultJiraJql = 'assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC';

class JiraCredentials {
  const JiraCredentials({required this.site, required this.email, required this.apiToken});

  /// Normalized site root, e.g. `https://your-team.atlassian.net`.
  final String site;
  final String email;
  final String apiToken;

  Uri get baseUri => Uri.parse(site);
  String get host => baseUri.host;

  /// Turns what people paste ("your-team", "your-team.atlassian.net", a full
  /// browser URL) into the site root. Returns null when it can't.
  static String? normalizeSite(String input) {
    var text = input.trim();
    if (text.isEmpty) return null;
    if (!text.contains('://')) text = 'https://$text';
    final uri = Uri.tryParse(text);
    if (uri == null || uri.host.isEmpty) return null;
    var host = uri.host.toLowerCase();
    if (!host.contains('.')) host = '$host.atlassian.net';
    return Uri(
      scheme: uri.scheme == 'http' ? 'http' : 'https',
      host: host,
      port: uri.hasPort ? uri.port : null,
    ).toString();
  }

  factory JiraCredentials.fromJson(Map<String, dynamic> json) => JiraCredentials(
        site: json['site'] as String,
        email: json['email'] as String,
        apiToken: json['apiToken'] as String,
      );

  Map<String, dynamic> toJson() => {'site': site, 'email': email, 'apiToken': apiToken};
}

class JiraUser {
  const JiraUser({required this.accountId, required this.displayName, this.emailAddress});

  final String accountId;
  final String displayName;

  /// Hidden by some accounts' privacy settings.
  final String? emailAddress;

  factory JiraUser.fromJson(Map<String, dynamic> json) => JiraUser(
        accountId: json['accountId'] as String? ?? '',
        displayName: json['displayName'] as String? ?? 'Jira user',
        emailAddress: json['emailAddress'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'accountId': accountId,
        'displayName': displayName,
        'emailAddress': emailAddress,
      };
}

class JiraIssue {
  const JiraIssue({
    required this.key,
    required this.summary,
    this.description = '',
    this.status = '',
    this.statusCategory = '',
    this.issueType = '',
    this.projectName = '',
    this.priority = '',
    this.fullDescription = '',
    this.descriptionRuns = const [],
    this.assigneeAccountId,
    this.created,
    this.assignedAt,
    this.dueDate,
    this.originalEstimateMinutes,
    this.remainingEstimateMinutes,
    this.timeSpentMinutes,
  });

  /// e.g. `CDEV-2228`.
  final String key;

  /// The issue's title.
  final String summary;

  /// Plain text on one line, flattened from Jira's rich-text format.
  final String description;

  /// The description as plain text with its paragraphs and list items kept.
  final String fullDescription;

  /// [fullDescription] split into plain text and links, for display.
  final List<JiraTextRun> descriptionRuns;

  /// Status name, i.e. the board column ("In Progress", "Ready for Test"…).
  final String status;

  /// Jira's coarse status: `new`, `indeterminate` (in progress) or `done`.
  final String statusCategory;
  final String issueType;
  final String projectName;

  /// Priority name ("High", "Medium"…), empty when the project has none.
  final String priority;
  final String? assigneeAccountId;
  final DateTime? created;

  /// When the current assignee got the issue: the latest assignee change to
  /// them in the changelog, or the creation date if it was never reassigned.
  final DateTime? assignedAt;

  /// Due day (date only), when set.
  final DateTime? dueDate;

  /// Jira time tracking, in minutes, when the project uses it.
  final int? originalEstimateMinutes;
  final int? remainingEstimateMinutes;
  final int? timeSpentMinutes;

  /// 0 for the most urgent; unknown priorities sort as medium.
  int get priorityRank => jiraPriorityRank(priority);

  factory JiraIssue.fromJson(Map<String, dynamic> json) {
    final fields = (json['fields'] as Map?)?.cast<String, dynamic>() ?? const {};
    final status = (fields['status'] as Map?)?.cast<String, dynamic>();
    final assignee = (fields['assignee'] as Map?)?['accountId'] as String?;
    final created = _parseDate(fields['created']);
    final runs = adfToRuns(fields['description']);

    DateTime? assignedAt;
    if (assignee != null) {
      final histories = (json['changelog'] as Map?)?['histories'] as List<dynamic>?;
      for (final history in histories ?? const []) {
        if (history is! Map) continue;
        final at = _parseDate(history['created']);
        if (at == null) continue;
        for (final item in history['items'] as List<dynamic>? ?? const []) {
          if (item is Map &&
              (item['fieldId'] ?? item['field']) == 'assignee' &&
              item['to'] == assignee &&
              (assignedAt == null || at.isAfter(assignedAt))) {
            assignedAt = at;
          }
        }
      }
      assignedAt ??= created;
    }

    final tracking = (fields['timetracking'] as Map?)?.cast<String, dynamic>() ?? const {};
    int? minutes(Object? seconds) => seconds is num && seconds > 0 ? (seconds / 60).round() : null;
    final due = fields['duedate'];

    return JiraIssue(
      key: json['key'] as String? ?? '',
      summary: (fields['summary'] as String? ?? '').trim(),
      description: adfToText(fields['description']),
      fullDescription: runs.map((r) => r.text).join(),
      descriptionRuns: runs,
      status: status?['name'] as String? ?? '',
      statusCategory: (status?['statusCategory'] as Map?)?['key'] as String? ?? '',
      issueType: (fields['issuetype'] as Map?)?['name'] as String? ?? '',
      projectName: (fields['project'] as Map?)?['name'] as String? ?? '',
      priority: (fields['priority'] as Map?)?['name'] as String? ?? '',
      assigneeAccountId: assignee,
      created: created,
      assignedAt: assignedAt,
      dueDate: due is String ? DateTime.tryParse(due) : null,
      originalEstimateMinutes:
          minutes(tracking['originalEstimateSeconds'] ?? fields['timeoriginalestimate']),
      remainingEstimateMinutes: minutes(tracking['remainingEstimateSeconds'] ?? fields['timeestimate']),
      timeSpentMinutes: minutes(tracking['timeSpentSeconds'] ?? fields['timespent']),
    );
  }
}

DateTime? _parseDate(Object? value) => value is String ? DateTime.tryParse(value) : null;

/// Orders Jira's default and common custom priority names, most urgent first.
int jiraPriorityRank(String priority) => switch (priority.trim().toLowerCase()) {
      'highest' || 'blocker' || 'critical' || 'urgent' => 0,
      'high' || 'major' => 1,
      'low' || 'minor' => 3,
      'lowest' || 'trivial' => 4,
      _ => 2,
    };

/// Flattens an Atlassian Document Format value (API v3 rich text) to one line
/// of plain text. Plain strings (API v2) pass through, whitespace collapsed.
String adfToText(Object? node) {
  if (node == null) return '';
  if (node is String) return _collapse(node);
  final out = StringBuffer();
  void walk(Object? n) {
    if (n is List) {
      for (final child in n) {
        walk(child);
      }
      return;
    }
    if (n is! Map) return;
    switch (n['type']) {
      case 'text':
        out.write(n['text'] ?? '');
        return;
      case 'hardBreak':
        out.write(' ');
        return;
      case 'mention' || 'emoji' || 'status':
        final text = (n['attrs'] as Map?)?['text'];
        if (text != null) out.write(text);
        return;
    }
    final content = n['content'];
    if (content is List) {
      walk(content);
      out.write(' '); // Separate paragraphs, list items, cells…
    }
  }

  walk(node);
  return _collapse(out.toString());
}

String _collapse(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

/// A piece of a description: plain text, or a link to [url].
class JiraTextRun {
  const JiraTextRun(this.text, [this.url]);

  final String text;
  final String? url;

  bool get isLink => url != null;
}

final _bareUrl = RegExp(r'''https?://[^\s<>"'\)\]]+''');

/// Splits a description (Atlassian Document Format, or a plain string) into
/// text and links, keeping paragraphs, line breaks and list items ("• item").
/// Linked text, link cards and bare URLs in the text all become links.
List<JiraTextRun> adfToRuns(Object? node) {
  if (node == null) return const [];
  final raw = <JiraTextRun>[];
  void add(String text, [String? url]) {
    if (text.isNotEmpty) raw.add(JiraTextRun(text, url));
  }

  const blocks = {'paragraph', 'heading', 'codeBlock', 'blockquote', 'tableRow', 'mediaSingle', 'panel'};
  void walk(Object? n) {
    if (n is List) {
      for (final child in n) {
        walk(child);
      }
      return;
    }
    if (n is! Map) return;
    final type = n['type'];
    final attrs = n['attrs'] as Map?;
    switch (type) {
      case 'text':
        String? href;
        for (final mark in n['marks'] as List<dynamic>? ?? const []) {
          if (mark is Map && mark['type'] == 'link') href = (mark['attrs'] as Map?)?['href'] as String?;
        }
        add(n['text'] as String? ?? '', href);
        return;
      case 'hardBreak' || 'rule':
        add('\n');
        return;
      case 'mention' || 'emoji' || 'status':
        add('${attrs?['text'] ?? ''}');
        return;
      case 'inlineCard' || 'blockCard' || 'embedCard':
        final url = attrs?['url'] as String?;
        if (url != null) add(url, url);
        return;
      case 'listItem':
        add('• '); // Its paragraphs follow below.
      case 'tableCell' || 'tableHeader':
        walk(n['content']);
        add('  ');
        return;
    }
    walk(n['content']);
    if (blocks.contains(type)) add('\n');
  }

  if (node is String) {
    add(node);
  } else {
    walk(node);
  }
  return _normalizeRuns(raw);
}

/// Merges neighbours, links bare URLs, tidies whitespace and trims the ends.
List<JiraTextRun> _normalizeRuns(List<JiraTextRun> raw) {
  List<JiraTextRun> merge(List<JiraTextRun> runs) {
    final out = <JiraTextRun>[];
    for (final run in runs) {
      if (out.isNotEmpty && out.last.url == run.url) {
        out[out.length - 1] = JiraTextRun(out.last.text + run.text, run.url);
      } else {
        out.add(run);
      }
    }
    return out;
  }

  String tidy(String text) => text
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAll(RegExp(r' *\n *'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n');

  final linked = <JiraTextRun>[];
  for (final run in merge(raw)) {
    if (run.isLink) {
      linked.add(JiraTextRun(tidy(run.text), run.url));
      continue;
    }
    final text = tidy(run.text);
    var start = 0;
    for (final match in _bareUrl.allMatches(text)) {
      // A sentence's full stop or comma isn't part of the address.
      var url = match.group(0)!;
      while (url.isNotEmpty && '.,;:!?'.contains(url[url.length - 1])) {
        url = url.substring(0, url.length - 1);
      }
      if (match.start > start) linked.add(JiraTextRun(text.substring(start, match.start)));
      linked.add(JiraTextRun(url, url));
      start = match.start + url.length;
    }
    if (start < text.length) linked.add(JiraTextRun(text.substring(start)));
  }

  final runs = merge(linked);
  while (runs.isNotEmpty && runs.first.text.trimLeft().isEmpty) {
    runs.removeAt(0);
  }
  while (runs.isNotEmpty && runs.last.text.trimRight().isEmpty) {
    runs.removeLast();
  }
  if (runs.isEmpty) return const [];
  runs[0] = JiraTextRun(runs.first.text.trimLeft(), runs.first.url);
  runs[runs.length - 1] = JiraTextRun(runs.last.text.trimRight(), runs.last.url);
  return runs;
}

/// Like [adfToText], but keeps paragraphs, line breaks and list items
/// ("• item") for reading the whole description.
String adfToMultilineText(Object? node) => adfToRuns(node).map((r) => r.text).join();

/// A move the issue's workflow allows from its current status.
class JiraTransition {
  const JiraTransition({
    required this.id,
    required this.name,
    required this.toStatus,
    required this.toCategory,
  });

  final String id;

  /// The workflow's name for the move, often the same as [toStatus].
  final String name;
  final String toStatus;

  /// `new`, `indeterminate` or `done`.
  final String toCategory;

  factory JiraTransition.fromJson(Map<String, dynamic> json) {
    final to = (json['to'] as Map?)?.cast<String, dynamic>();
    return JiraTransition(
      id: '${json['id']}',
      name: json['name'] as String? ?? '',
      toStatus: to?['name'] as String? ?? json['name'] as String? ?? '',
      toCategory: (to?['statusCategory'] as Map?)?['key'] as String? ?? '',
    );
  }
}

final _issueKey = RegExp(r'^[A-Za-z][A-Za-z0-9_]+-\d+$');
final _orderBy = RegExp(r'\s*\border\s+by\b.*$', caseSensitive: false, dotAll: true);
final _notWordOrSpace = RegExp(r'[^\p{L}\p{N}\s]', unicode: true);

/// Whether [text] looks like an issue key, e.g. `CDEV-2228`.
bool isJiraIssueKey(String text) => _issueKey.hasMatch(text.trim());

/// Whether [issue]'s key, title or description contains [query] (any case).
bool jiraIssueContains(JiraIssue issue, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return true;
  return issue.key.toLowerCase().contains(needle) ||
      issue.summary.toLowerCase().contains(needle) ||
      issue.fullDescription.toLowerCase().contains(needle) ||
      issue.description.toLowerCase().contains(needle);
}

/// The JQL for task search: [filter] (the saved list query) narrowed to
/// issues whose title or description has words starting like what was typed.
/// Typing an issue key looks that issue up directly, even if the filter would
/// hide it.
String buildJiraJql(String filter, String query) {
  final typed = query.trim();
  if (_issueKey.hasMatch(typed)) return 'key = ${typed.toUpperCase()}';

  final base = filter.trim().isEmpty ? defaultJiraJql : filter.trim();
  // Jira's text search treats punctuation as operators; keep words only.
  final words = typed.replaceAll(_notWordOrSpace, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (words.isEmpty) return base;

  final order = _orderBy.firstMatch(base);
  final where = (order == null ? base : base.substring(0, order.start)).trim();
  final orderBy = order == null ? ' ORDER BY updated DESC' : ' ${base.substring(order.start).trim()}';
  final text = '(summary ~ "$words*" OR description ~ "$words*")';
  return where.isEmpty ? '$text$orderBy' : '($where) AND $text$orderBy';
}
