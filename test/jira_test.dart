import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timmy/core/jira_client.dart';
import 'package:timmy/core/storage.dart';
import 'package:timmy/models/jira.dart';
import 'package:timmy/state/jira_controller.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

const _creds = JiraCredentials(
  site: 'https://acme.atlassian.net',
  email: 'me@acme.test',
  apiToken: 'secret',
);

final _issueJson = {
  'id': '10001',
  'key': 'CDEV-2228',
  'fields': {
    'summary': 'Pay Now Functional',
    'description': {
      'type': 'doc',
      'version': 1,
      'content': [
        {
          'type': 'paragraph',
          'content': [
            {'type': 'text', 'text': 'Wire the '},
            {'type': 'text', 'text': 'Pay Now', 'marks': [{'type': 'strong'}]},
            {'type': 'text', 'text': ' button.'},
          ],
        },
        {
          'type': 'bulletList',
          'content': [
            {
              'type': 'listItem',
              'content': [
                {'type': 'paragraph', 'content': [{'type': 'text', 'text': 'Handle errors'}]},
              ],
            },
          ],
        },
      ],
    },
    'status': {'name': 'In Progress', 'statusCategory': {'key': 'indeterminate'}},
    'issuetype': {'name': 'Story'},
    'project': {'name': 'Checkout'},
    'priority': {'name': 'High'},
    'assignee': {'accountId': 'a1', 'displayName': 'Edgar P'},
    'created': '2026-09-01T10:00:00.000+0400',
  },
  'changelog': {
    'histories': [
      {
        'created': '2026-09-20T09:00:00.000+0400',
        'items': [
          {'field': 'assignee', 'fieldId': 'assignee', 'from': null, 'to': 'a1'},
        ],
      },
      {
        'created': '2026-09-10T09:00:00.000+0400',
        'items': [
          {'field': 'assignee', 'fieldId': 'assignee', 'from': null, 'to': 'someone-else'},
        ],
      },
      {
        'created': '2026-09-25T09:00:00.000+0400',
        'items': [
          {'field': 'status', 'fieldId': 'status', 'from': '1', 'to': '3'},
        ],
      },
    ],
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('JiraCredentials.normalizeSite', () {
    test('accepts a bare team name, a host or a full browser URL', () {
      expect(JiraCredentials.normalizeSite('acme'), 'https://acme.atlassian.net');
      expect(JiraCredentials.normalizeSite(' acme.atlassian.net '), 'https://acme.atlassian.net');
      expect(
        JiraCredentials.normalizeSite('https://Acme.atlassian.net/jira/your-work?x=1'),
        'https://acme.atlassian.net',
      );
    });

    test('rejects empty input', () {
      expect(JiraCredentials.normalizeSite('   '), isNull);
    });
  });

  group('buildJiraJql', () {
    test('uses the filter as is when nothing is typed', () {
      expect(buildJiraJql(defaultJiraJql, ''), defaultJiraJql);
      expect(buildJiraJql('', ''), defaultJiraJql);
    });

    test('looks a typed key up directly', () {
      expect(buildJiraJql(defaultJiraJql, ' cdev-2228 '), 'key = CDEV-2228');
    });

    test('searches title and description before the filter\'s ORDER BY', () {
      expect(
        buildJiraJql(defaultJiraJql, 'pay now'),
        '(assignee = currentUser() AND statusCategory != Done) AND '
        '(summary ~ "pay now*" OR description ~ "pay now*") ORDER BY updated DESC',
      );
      expect(
        buildJiraJql('project = CDEV', 'pay'),
        '(project = CDEV) AND (summary ~ "pay*" OR description ~ "pay*") ORDER BY updated DESC',
      );
    });

    test('strips characters Jira\'s text search would choke on', () {
      expect(
        buildJiraJql('project = X', 'pay "now" (v2)!'),
        '(project = X) AND (summary ~ "pay now v2*" OR description ~ "pay now v2*") ORDER BY updated DESC',
      );
      expect(buildJiraJql('project = X', '"!?'), 'project = X');
    });
  });

  test('adfToMultilineText keeps paragraphs and list items', () {
    expect(
      adfToMultilineText((_issueJson['fields'] as Map)['description']),
      'Wire the Pay Now button.\n• Handle errors',
    );
    expect(adfToMultilineText(null), '');
  });

  test('adfToRuns turns linked text, link cards and bare URLs into links', () {
    final runs = adfToRuns({
      'type': 'doc',
      'content': [
        {
          'type': 'paragraph',
          'content': [
            {'type': 'text', 'text': 'Figma '},
            {
              'type': 'text',
              'text': 'link',
              'marks': [
                {'type': 'link', 'attrs': {'href': 'https://figma.com/file/abc'}},
              ],
            },
            {'type': 'text', 'text': ' and see https://example.com/spec.'},
          ],
        },
        {
          'type': 'paragraph',
          'content': [
            {'type': 'inlineCard', 'attrs': {'url': 'https://acme.atlassian.net/browse/CDEV-1'}},
          ],
        },
      ],
    });
    expect([for (final r in runs) (r.text, r.url)], [
      ('Figma ', null),
      ('link', 'https://figma.com/file/abc'),
      (' and see ', null),
      ('https://example.com/spec', 'https://example.com/spec'), // Full stop left out.
      ('.\n', null),
      ('https://acme.atlassian.net/browse/CDEV-1', 'https://acme.atlassian.net/browse/CDEV-1'),
    ]);
    // Plain descriptions (API v2 strings) get their URLs linked too.
    expect(adfToRuns('See http://x.test/a, thanks').where((r) => r.isLink).single.url, 'http://x.test/a');
  });

  test('jiraIssueContains matches inside words, in title, description or key', () {
    final issue = JiraIssue.fromJson(_issueJson);
    expect(jiraIssueContains(issue, 'now func'), isTrue); // title, mid-phrase
    expect(jiraIssueContains(issue, 'ANDLE ERR'), isTrue); // description, any case
    expect(jiraIssueContains(issue, '2228'), isTrue); // key
    expect(jiraIssueContains(issue, 'checkout'), isFalse); // project name doesn't count
  });

  test('adfToText flattens rich text to one line', () {
    expect(
      adfToText((_issueJson['fields'] as Map)['description']),
      'Wire the Pay Now button. Handle errors',
    );
    expect(adfToText('  plain\n\ntext '), 'plain text');
    expect(adfToText(null), '');
  });

  group('JiraClient', () {
    test('search calls the enhanced search endpoint with basic auth', () async {
      late http.Request seen;
      final client = JiraClient(httpClient: MockClient((req) async {
        seen = req;
        return _json({'issues': [_issueJson], 'isLast': true});
      }));

      final issues = await client.search(_creds, jql: 'key = CDEV-2228');

      expect(seen.url.path, '/rest/api/3/search/jql');
      expect(seen.url.host, 'acme.atlassian.net');
      expect(seen.url.queryParameters['jql'], 'key = CDEV-2228');
      expect(seen.url.queryParameters['fields'], contains('description'));
      expect(
        seen.headers['Authorization'],
        'Basic ${base64Encode(utf8.encode('me@acme.test:secret'))}',
      );
      final issue = issues.single;
      expect(issue.key, 'CDEV-2228');
      expect(issue.summary, 'Pay Now Functional');
      expect(issue.description, 'Wire the Pay Now button. Handle errors');
      expect(issue.status, 'In Progress');
      expect(issue.statusCategory, 'indeterminate');
      expect(issue.projectName, 'Checkout');
      expect(issue.priority, 'High');
      expect(issue.priorityRank, 1);
      expect(issue.assigneeAccountId, 'a1');
      expect(seen.url.queryParameters['expand'], 'changelog');
      expect(seen.url.queryParameters['fields'], contains('priority'));
    });

    test('assignedAt is the latest hand-over to the assignee, else creation', () {
      final issue = JiraIssue.fromJson(_issueJson);
      expect(issue.assignedAt, DateTime.parse('2026-09-20T09:00:00.000+0400'));

      final neverReassigned = JiraIssue.fromJson({
        'key': 'CDEV-1',
        'fields': {
          'summary': 'x',
          'assignee': {'accountId': 'a1'},
          'created': '2026-09-01T10:00:00.000+0400',
        },
      });
      expect(neverReassigned.assignedAt, DateTime.parse('2026-09-01T10:00:00.000+0400'));

      final unassigned = JiraIssue.fromJson({'key': 'CDEV-2', 'fields': {'summary': 'y'}});
      expect(unassigned.assignedAt, isNull);
    });

    test('priority ranks put the most urgent first', () {
      expect(jiraPriorityRank('Highest'), lessThan(jiraPriorityRank('High')));
      expect(jiraPriorityRank('High'), lessThan(jiraPriorityRank('Medium')));
      expect(jiraPriorityRank('Medium'), lessThan(jiraPriorityRank('Low')));
      expect(jiraPriorityRank('Low'), lessThan(jiraPriorityRank('Lowest')));
      expect(jiraPriorityRank('Something custom'), jiraPriorityRank('Medium'));
    });

    test('lists transitions and moves an issue with POST', () async {
      final seen = <http.Request>[];
      final client = JiraClient(httpClient: MockClient((req) async {
        seen.add(req);
        if (req.method == 'GET') {
          return _json({
            'transitions': [
              {
                'id': '21',
                'name': 'Start progress',
                'to': {'name': 'In Progress', 'statusCategory': {'key': 'indeterminate'}},
              },
              {
                'id': '31',
                'name': 'Done',
                'to': {'name': 'Done', 'statusCategory': {'key': 'done'}},
              },
            ],
          });
        }
        return http.Response('', 204);
      }));

      final transitions = await client.transitions(_creds, 'CDEV-2228');
      expect(seen.last.url.path, '/rest/api/3/issue/CDEV-2228/transitions');
      expect(transitions.first.id, '21');
      expect(transitions.first.name, 'Start progress');
      expect(transitions.first.toStatus, 'In Progress');
      expect(transitions.first.toCategory, 'indeterminate');

      await client.transition(_creds, 'CDEV-2228', '31');
      expect(seen.last.method, 'POST');
      expect(seen.last.url.path, '/rest/api/3/issue/CDEV-2228/transitions');
      expect(jsonDecode(seen.last.body), {
        'transition': {'id': '31'},
      });
    });

    test('explains bad credentials and JQL errors', () async {
      final unauthorized = JiraClient(httpClient: MockClient((_) async => http.Response('', 401)));
      await expectLater(
        unauthorized.myself(_creds),
        throwsA(isA<JiraException>().having((e) => e.message, 'message', contains('API token'))),
      );

      final badJql = JiraClient(httpClient: MockClient(
        (_) async => _json({'errorMessages': ["Field 'foo' does not exist."]}, 400),
      ));
      await expectLater(
        badJql.search(_creds, jql: 'foo = 1'),
        throwsA(isA<JiraException>().having((e) => e.message, 'message', "Field 'foo' does not exist.")),
      );
    });
  });

  group('JiraController', () {
    late AppStorage storage;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      storage = AppStorage(await SharedPreferences.getInstance());
    });

    JiraClient fakeJira({bool accept = true}) => JiraClient(httpClient: MockClient((req) async {
          if (!accept) return http.Response('', 401);
          if (req.url.path == '/rest/api/3/myself') {
            return _json({'accountId': 'a1', 'displayName': 'Edgar P', 'emailAddress': 'me@acme.test'});
          }
          return _json({'issues': [_issueJson]});
        }));

    test('connect verifies and saves; a new controller restores it', () async {
      final jira = JiraController(client: fakeJira(), storage: storage, userId: 64);
      await jira.connect(site: 'acme', email: 'me@acme.test', apiToken: 'secret');

      expect(jira.isConnected, isTrue);
      expect(jira.account!.displayName, 'Edgar P');
      expect(jira.credentials!.site, 'https://acme.atlassian.net');

      final restored = JiraController(client: fakeJira(), storage: storage, userId: 64);
      expect(restored.isConnected, isTrue);
      expect((await restored.search('')).single.key, 'CDEV-2228');

      // Another Timmy user doesn't inherit the connection.
      expect(JiraController(client: fakeJira(), storage: storage, userId: 65).isConnected, isFalse);
    });

    test('rejected credentials are not saved', () async {
      final jira = JiraController(client: fakeJira(accept: false), storage: storage, userId: 64);
      await expectLater(
        jira.connect(site: 'acme', email: 'me@acme.test', apiToken: 'wrong'),
        throwsA(isA<JiraException>()),
      );
      expect(jira.isConnected, isFalse);
      expect(jira.connecting, isFalse);
    });

    test('disconnect forgets the token', () async {
      final jira = JiraController(client: fakeJira(), storage: storage, userId: 64);
      await jira.connect(site: 'acme', email: 'me@acme.test', apiToken: 'secret');
      await jira.disconnect();
      expect(JiraController(client: fakeJira(), storage: storage, userId: 64).isConnected, isFalse);
    });

    test('findTasks keeps only issues whose title or description contains the text', () async {
      final queries = <String>[];
      final client = JiraClient(httpClient: MockClient((req) async {
        if (req.url.path == '/rest/api/3/myself') {
          return _json({'accountId': 'a1', 'displayName': 'Edgar P'});
        }
        final jql = req.url.queryParameters['jql']!;
        queries.add(jql);
        Map<String, dynamic> issue(String key, String summary) => {
              'key': key,
              'fields': {'summary': summary, 'status': {'name': 'To Do'}},
            };
        // Jira's word search finds nothing for a partial word; the saved
        // list has both issues.
        if (jql.contains('summary ~')) return _json({'issues': <Object>[]});
        return _json({
          'issues': [issue('CDEV-1', 'Canvas Save and Edit'), issue('CDEV-2', 'UDW List')],
        });
      }));
      final jira = JiraController(client: client, storage: storage, userId: 64);
      await jira.connect(site: 'acme', email: 'me@acme.test', apiToken: 'secret');

      final found = await jira.findTasks('anvas sa');
      expect(found.map((i) => i.key), ['CDEV-1']);
      expect(queries.where((q) => q.contains('summary ~ "anvas sa*"')), hasLength(1));

      // The saved list is reused while typing, then refetched on refresh.
      final before = queries.length;
      await jira.findTasks('');
      expect(queries.length, before);
      await jira.findTasks('', refresh: true);
      expect(queries.length, before + 1);

      // A key goes straight to that issue.
      await jira.findTasks('cdev-2');
      expect(queries.last, 'key = CDEV-2');
    });

    test('taskFor follows the chosen title format', () async {
      final jira = JiraController(client: fakeJira(), storage: storage, userId: 64);
      final issue = JiraIssue.fromJson(_issueJson);

      expect(jira.taskFor(issue).title, 'CDEV-2228 Pay Now Functional');
      expect(jira.taskFor(issue).description, isNull);

      await jira.setTitleFormat(JiraTitleFormat.keyOnly);
      expect(jira.taskFor(issue).title, 'CDEV-2228');
      expect(jira.taskFor(issue).description, 'Pay Now Functional');
    });
  });
}
