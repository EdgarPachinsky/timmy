import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/jira.dart';

class JiraException implements Exception {
  const JiraException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Minimal Jira Cloud REST client (API v3), signed in with an account email and
/// an API token (HTTP basic auth).
class JiraClient {
  JiraClient({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  static const _timeout = Duration(seconds: 20);
  static const _issueFields =
      'summary,description,status,issuetype,project,priority,assignee,created,duedate,timetracking';

  final http.Client _http;

  /// The account the credentials belong to; used to verify a connection.
  Future<JiraUser> myself(JiraCredentials credentials) async => JiraUser.fromJson(
      await _get(credentials, '/rest/api/3/myself') as Map<String, dynamic>);

  /// Issues matching [jql] (enhanced search; `/rest/api/3/search` is retired).
  Future<List<JiraIssue>> search(
    JiraCredentials credentials, {
    required String jql,
    int maxResults = 40,
  }) async {
    final json = await _get(credentials, '/rest/api/3/search/jql', query: {
      'jql': jql,
      'fields': _issueFields,
      // The changelog tells when the issue was assigned to its assignee.
      'expand': 'changelog',
      'maxResults': '$maxResults',
    }) as Map<String, dynamic>;
    return [
      for (final issue in json['issues'] as List<dynamic>? ?? const [])
        JiraIssue.fromJson(issue as Map<String, dynamic>),
    ];
  }

  /// Status moves the issue's workflow allows from where it is now.
  Future<List<JiraTransition>> transitions(JiraCredentials credentials, String issueKey) async {
    final json = await _get(credentials, '/rest/api/3/issue/$issueKey/transitions') as Map<String, dynamic>;
    return [
      for (final t in json['transitions'] as List<dynamic>? ?? const [])
        JiraTransition.fromJson(t as Map<String, dynamic>),
    ];
  }

  /// Moves the issue to another status (column) via [transitionId].
  Future<void> transition(JiraCredentials credentials, String issueKey, String transitionId) =>
      _send(
        credentials,
        'POST',
        '/rest/api/3/issue/$issueKey/transitions',
        body: {
          'transition': {'id': transitionId},
        },
      );

  Future<dynamic> _get(
    JiraCredentials credentials,
    String path, {
    Map<String, String>? query,
  }) =>
      _send(credentials, 'GET', path, query: query);

  Future<dynamic> _send(
    JiraCredentials credentials,
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    final uri = credentials.baseUri.replace(path: path, queryParameters: query);
    final auth = base64Encode(utf8.encode('${credentials.email}:${credentials.apiToken}'));
    final request = http.Request(method, uri)
      ..headers['Accept'] = 'application/json'
      ..headers['Authorization'] = 'Basic $auth';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }

    final http.Response response;
    try {
      response = await http.Response.fromStream(await _http.send(request).timeout(_timeout));
    } on TimeoutException {
      throw const JiraException('Jira took too long to respond.');
    } on IOException {
      throw JiraException("Can't reach ${credentials.host}. Check the site address and your connection.");
    } on http.ClientException {
      throw JiraException("Can't reach ${credentials.host}. Check the site address and your connection.");
    }

    dynamic decoded;
    if (response.bodyBytes.isNotEmpty) {
      try {
        decoded = jsonDecode(utf8.decode(response.bodyBytes));
      } on FormatException {
        decoded = null;
      }
    }

    final status = response.statusCode;
    // Reads must return JSON; writes may answer 204 No Content.
    if (status >= 200 && status < 300 && (decoded != null || method != 'GET')) return decoded;

    throw JiraException(
      switch (status) {
        401 => 'Jira rejected the email or API token.',
        403 => "Jira refused access. Sign in to Jira in a browser once, then try again.",
        404 => "Couldn't find Jira at ${credentials.host}. Check the site address.",
        _ when status >= 200 && status < 300 => "${credentials.host} didn't answer like Jira does. Check the site address.",
        _ => _jiraMessage(decoded) ?? 'Jira request failed ($status).',
      },
      statusCode: status,
    );
  }

  /// Jira reports errors as `errorMessages: [...]` and/or `errors: {field: msg}`.
  static String? _jiraMessage(dynamic body) {
    if (body is! Map) return null;
    final messages = [
      for (final m in body['errorMessages'] as List<dynamic>? ?? const []) '$m',
      for (final m in (body['errors'] as Map?)?.values ?? const []) '$m',
    ];
    return messages.isEmpty ? null : messages.join(' ');
  }
}
