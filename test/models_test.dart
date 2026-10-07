import 'package:flutter_test/flutter_test.dart';
import 'package:timmy/models/models.dart';

// Payloads copied from the real API responses.
const projectWithClient = {
  'id': 38,
  'workspaceId': 36,
  'clientId': 42,
  'client': {
    'id': 42,
    'workspaceId': 36,
    'firstName': 'Carl',
    'lastName': 'Briganti',
    'description': 'carlb@cssimpact.com',
    'createdAt': '2026-06-18T10:29:16.342Z',
    'updatedAt': '2026-06-18T10:36:39.111Z',
  },
  'teamId': 32,
  'name': 'CSS',
  'description': null,
  'color': '#10b981',
  'status': 'active',
  'memberCount': 7,
  'totalMinutes': 69150,
  'createdAt': '2026-06-18T10:41:37.260Z',
};

const projectWithoutClient = {
  'id': 62,
  'workspaceId': 36,
  'clientId': null,
  'client': null,
  'teamId': null,
  'name': 'STDev internal requests',
  'description': null,
  'color': '#ef4444',
  'status': 'active',
  'memberCount': 45,
  'totalMinutes': 11445,
  'createdAt': '2026-06-29T11:14:02.940Z',
};

void main() {
  test('parses a project with a client', () {
    final p = Project.fromJson(projectWithClient);
    expect(p.name, 'CSS');
    expect(p.client?.fullName, 'Carl Briganti');
    expect(p.color.toARGB32(), 0xFF10B981);
    expect(p.isActive, isTrue);
    expect(p.totalMinutes, 69150);
  });

  test('parses a project with null client', () {
    final p = Project.fromJson(projectWithoutClient);
    expect(p.client, isNull);
    expect(p.name, 'STDev internal requests');
  });

  test('parses a workspace with null description', () {
    final w = Workspace.fromJson({
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
    });
    expect(w.name, 'STDev');
    expect(w.timezone, 'Asia/Yerevan');
    expect(w.myRole, 'member');
  });

  test('parses a time entry with tags and nullable description', () {
    final e = TimeEntry.fromJson({
      'id': 143,
      'workspaceId': 36,
      'projectId': 38,
      'userId': 64,
      'taskTitle': 'CDEV-2228',
      'description': null,
      'hours': 8,
      'minutes': 0,
      'totalMinutes': 480,
      'date': '2026-06-29',
      'billable': true,
      'project': projectWithClient,
      'user': {'id': 64, 'email': 'edgar.pachinsky@stdevmail.com', 'name': 'Edgar Pachinsky', 'role': 'user'},
      'tags': [
        {
          'id': 88,
          'workspaceId': 36,
          'name': 'New Feature',
          'color': '#22c55e',
          'createdAt': '2026-06-18T10:50:24.240Z',
        },
      ],
      'createdAt': '2026-06-29T12:10:22.222Z',
    });
    expect(e.totalMinutes, 480);
    expect(e.description, isNull);
    expect(e.tags.single.name, 'New Feature');
    expect(e.project?.name, 'CSS');
    expect(e.date, '2026-06-29');
  });

  test('falls back to hours/minutes when totalMinutes is missing', () {
    final e = TimeEntry.fromJson({
      'id': 1,
      'projectId': 1,
      'taskTitle': 't',
      'hours': 2,
      'minutes': 15,
      'date': '2026-01-01',
      'billable': false,
    });
    expect(e.totalMinutes, 135);
    expect(e.tags, isEmpty);
  });

  test('colorFromHex tolerates bad input', () {
    expect(colorFromHex(null).toARGB32(), 0xFF94A3B8);
    expect(colorFromHex('nope').toARGB32(), 0xFF94A3B8);
    expect(colorFromHex('#zzzzzz').toARGB32(), 0xFF94A3B8);
  });

  test('user initials', () {
    const u = User(id: 1, email: 'e', name: 'Edgar Pachinsky', role: 'user');
    expect(u.initials, 'EP');
    const single = User(id: 1, email: 'e', name: 'Edgar', role: 'user');
    expect(single.initials, 'E');
  });
}
