import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:timmy/core/api_client.dart';

void main() {
  ApiClient clientFor(Future<http.Response> Function(http.Request) handler) =>
      ApiClient(baseUrl: 'https://api.test', httpClient: MockClient(handler));

  http.Response json(Object body, [int status = 200]) => http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  test('login posts credentials without an auth header and parses the result', () async {
    late http.Request seen;
    final api = clientFor((req) async {
      seen = req;
      return json({
        'user': {
          'id': 64,
          'email': 'edgar.pachinsky@stdevmail.com',
          'name': 'Edgar Pachinsky',
          'role': 'user',
          'createdAt': '2026-06-29T12:02:03.438Z',
        },
        'token': 'tokenString',
      });
    });

    final result = await api.login('edgar.pachinsky@stdevmail.com', 'pw');
    expect(seen.method, 'POST');
    expect(seen.url.toString(), 'https://api.test/api/auth/login');
    expect(jsonDecode(seen.body), {'email': 'edgar.pachinsky@stdevmail.com', 'password': 'pw'});
    expect(seen.headers.containsKey('Authorization'), isFalse);
    expect(result.token, 'tokenString');
    expect(result.user.name, 'Edgar Pachinsky');
  });

  test('authenticated calls send the bearer token', () async {
    late http.Request seen;
    final api = clientFor((req) async {
      seen = req;
      return json({'id': 64, 'email': 'e@x.test', 'name': 'E', 'role': 'user'});
    })
      ..token = 'abc';

    await api.me();
    expect(seen.url.path, '/api/auth/me');
    expect(seen.headers['Authorization'], 'Bearer abc');
  });

  test('projects and time entries use the documented query params', () async {
    final seen = <Uri>[];
    final api = clientFor((req) async {
      seen.add(req.url);
      return json([]);
    })
      ..token = 't';

    await api.projects(36, memberId: 64);
    await api.timeEntries(36, userId: 64);
    await api.tags(36);
    await api.workspaces();

    expect(seen[0].toString(), 'https://api.test/api/workspaces/36/projects?memberId=64');
    expect(seen[1].toString(), 'https://api.test/api/workspaces/36/time-entries?userId=64');
    expect(seen[2].toString(), 'https://api.test/api/workspaces/36/tags');
    expect(seen[3].toString(), 'https://api.test/api/workspaces');
  });

  test('createTimeEntry posts JSON to the workspace endpoint', () async {
    late http.Request seen;
    final api = clientFor((req) async {
      seen = req;
      return json({'id': 4643, 'projectId': 38, 'taskTitle': 'test', 'date': '2026-10-08', 'billable': true}, 201);
    })
      ..token = 't';

    final entry = await api.createTimeEntry(36, {'projectId': 38, 'taskTitle': 'test'});
    expect(seen.method, 'POST');
    expect(seen.url.path, '/api/workspaces/36/time-entries');
    expect(seen.headers['Content-Type'], contains('application/json'));
    expect(jsonDecode(seen.body), {'projectId': 38, 'taskTitle': 'test'});
    expect(entry.id, 4643);
  });

  test('server error messages are surfaced', () async {
    final api = clientFor((_) async => json({'error': 'Invalid credentials'}, 401));
    await expectLater(
      api.login('a@b.c', 'x'),
      throwsA(isA<ApiException>()
          .having((e) => e.message, 'message', 'Invalid credentials')
          .having((e) => e.statusCode, 'statusCode', 401)),
    );
  });

  test('401 on an authenticated call signals the session is gone', () async {
    var signalled = 0;
    final api = clientFor((_) async => json({'error': 'Unauthorized'}, 401))
      ..token = 'expired'
      ..onUnauthorized = () => signalled++;

    await expectLater(api.workspaces(), throwsA(isA<ApiException>()));
    expect(signalled, 1);
  });

  test('a failed login does not trigger the session-expired handler', () async {
    var signalled = 0;
    final api = clientFor((_) async => json({'error': 'Invalid credentials'}, 401))
      ..onUnauthorized = () => signalled++;

    await expectLater(api.login('a@b.c', 'x'), throwsA(isA<ApiException>()));
    expect(signalled, 0);
  });

  test('network failures become friendly errors', () async {
    final api = clientFor((_) async => throw const SocketException('no route'));
    await expectLater(
      api.workspaces(),
      throwsA(isA<ApiException>().having((e) => e.isNetwork, 'isNetwork', isTrue)),
    );
  });

  test('non-JSON error bodies still produce a readable message', () async {
    final api = clientFor((_) async => http.Response('<html>Bad gateway</html>', 502));
    await expectLater(
      api.workspaces(),
      throwsA(isA<ApiException>().having((e) => e.message, 'message', contains('502'))),
    );
  });

  test('refreshToken returns the new token', () async {
    final api = clientFor((req) async {
      expect(req.method, 'POST');
      expect(req.url.path, '/api/auth/refresh');
      return json({'token': 'fresh'});
    })
      ..token = 'old';
    expect(await api.refreshToken(), 'fresh');
  });

  test('updateTimeEntry PATCHes the entry and parses the reply', () async {
    late http.Request seen;
    final api = clientFor((req) async {
      seen = req;
      return json({
        'id': 4622,
        'workspaceId': 36,
        'projectId': 38,
        'userId': 64,
        'taskTitle': 'CDEV-2450',
        'description': 'fixing EDI issues',
        'hours': 1,
        'minutes': 46,
        'totalMinutes': 106,
        'date': '2026-10-07',
        'billable': true,
        'project': {
          'id': 38,
          'workspaceId': 36,
          'name': 'CSS',
          'description': null,
          'color': '#10b981',
          'status': 'active',
          'memberCount': 0,
          'totalMinutes': 0,
          'createdAt': '2026-06-18T10:41:37.260Z',
        },
        'tags': [
          {'id': 87, 'workspaceId': 36, 'name': 'Bug', 'color': '#ef4444', 'createdAt': '2026-06-18T10:50:13.074Z'},
        ],
        'createdAt': '2026-10-07T13:54:10.734Z',
      });
    })
      ..token = 'tokenString';

    final payload = {
      'billable': true,
      'date': '2026-10-07',
      'description': 'fixing EDI issues',
      'hours': 1,
      'minutes': 46,
      'projectId': 38,
      'tagIds': [87],
      'taskTitle': 'CDEV-2450',
    };
    final entry = await api.updateTimeEntry(36, 4622, payload);

    expect(seen.method, 'PATCH');
    expect(seen.url.toString(), 'https://api.test/api/workspaces/36/time-entries/4622');
    expect(seen.headers['Authorization'], 'Bearer tokenString');
    expect(jsonDecode(seen.body), payload);
    expect(entry.id, 4622);
    expect(entry.totalMinutes, 106);
    expect(entry.tags.single.name, 'Bug');
  });

  test('deleteTimeEntry sends DELETE to the entry', () async {
    late http.Request seen;
    final api = clientFor((req) async {
      seen = req;
      return http.Response('', 204);
    })
      ..token = 'tokenString';

    await api.deleteTimeEntry(36, 4649);
    expect(seen.method, 'DELETE');
    expect(seen.url.toString(), 'https://api.test/api/workspaces/36/time-entries/4649');
    expect(seen.headers['Authorization'], 'Bearer tokenString');
  });
}
