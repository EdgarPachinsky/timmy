import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../models_test.dart' show projectWithClient, projectWithoutClient;

const demoEmail = 'edgar.pachinsky@stdevmail.com';
const demoPassword = 'correct-horse';

const demoUser = {
  'id': 64,
  'email': demoEmail,
  'name': 'Edgar Pachinsky',
  'role': 'user',
  'createdAt': '2026-06-29T12:02:03.438Z',
};

const demoWorkspace = {
  'id': 36,
  'name': 'STDev',
  'description': null,
  'ownerId': 43,
  'dailyReportsEnabled': true,
  'timezone': 'Asia/Yerevan',
  'memberCount': 49,
  'projectCount': 34,
  'createdAt': '2026-06-18T10:27:06.972Z',
  'myRole': 'member',
};

Map<String, dynamic> _tag(int id, String name, String color) => {
      'id': id,
      'workspaceId': 36,
      'name': name,
      'color': color,
      'createdAt': '2026-06-18T10:50:13.074Z',
    };

final demoTags = [
  _tag(87, 'Bug', '#ef4444'),
  _tag(101, 'Call', '#6366f1'),
  _tag(93, 'Code Review', '#6366f1'),
  _tag(90, 'Development', '#3b82f6'),
  _tag(88, 'New Feature', '#22c55e'),
  _tag(92, 'Testing', '#8b5cf6'),
];

/// A scripted Time-Wise backend. Records what the app sends.
class FakeBackend {
  FakeBackend() {
    entries = [
      {
        'id': 143,
        'workspaceId': 36,
        'projectId': 38,
        'userId': 64,
        'taskTitle': 'CDEV-2228',
        'description': 'Pay Now Functional',
        'hours': 8,
        'minutes': 0,
        'totalMinutes': 480,
        'date': '2026-06-29',
        'billable': true,
        'project': projectWithClient,
        'tags': [demoTags[4]],
        'createdAt': '2026-06-29T12:10:22.222Z',
      },
    ];
  }

  late final List<Map<String, dynamic>> entries;
  final List<Map<String, dynamic>> postedEntries = [];
  final List<String> requests = [];

  /// When true, POSTing a time entry fails with a 500.
  bool failEntryPosts = false;

  late final MockClient client = MockClient(_handle);

  http.Response _json(Object body, [int status = 200]) => http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  Future<http.Response> _handle(http.Request req) async {
    final path = req.url.path;
    requests.add('${req.method} ${req.url.path}${req.url.hasQuery ? '?${req.url.query}' : ''}');

    if (path == '/api/auth/login') {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      if (body['email'] == demoEmail && body['password'] == demoPassword) {
        return _json({'user': demoUser, 'token': 'tokenString'});
      }
      return _json({'error': 'Invalid credentials'}, 401);
    }

    if (req.headers['Authorization'] != 'Bearer tokenString') {
      return _json({'error': 'Unauthorized'}, 401);
    }

    switch ((req.method, path)) {
      case ('GET', '/api/auth/me'):
        return _json(demoUser);
      case ('POST', '/api/auth/refresh'):
        return _json({'token': 'tokenString'});
      case ('POST', '/api/auth/logout'):
        return _json({'ok': true});
      case ('GET', '/api/workspaces'):
        return _json([demoWorkspace]);
      case ('GET', '/api/workspaces/36/projects'):
        return _json([projectWithClient, projectWithoutClient]);
      case ('GET', '/api/workspaces/36/tags'):
        return _json(demoTags);
      case ('GET', '/api/workspaces/36/time-entries'):
        return _json(entries);
      case ('POST', '/api/workspaces/36/time-entries'):
        if (failEntryPosts) return _json({'error': 'Something went wrong'}, 500);
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        postedEntries.add(body);
        final project = body['projectId'] == 38 ? projectWithClient : projectWithoutClient;
        final entry = {
          'id': 4643 + postedEntries.length,
          'workspaceId': 36,
          'userId': 64,
          ...body,
          'totalMinutes': (body['hours'] as int) * 60 + (body['minutes'] as int),
          'project': project,
          'tags': [
            for (final t in demoTags)
              if ((body['tagIds'] as List).contains(t['id'])) t,
          ],
          'createdAt': DateTime.now().toUtc().toIso8601String(),
        };
        entries.add(entry);
        return _json(entry, 201);
    }
    return _json({'error': 'Not found'}, 404);
  }
}
