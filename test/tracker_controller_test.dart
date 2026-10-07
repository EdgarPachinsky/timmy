import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timmy/core/api_client.dart';
import 'package:timmy/core/storage.dart';
import 'package:timmy/models/models.dart';
import 'package:timmy/state/tracker_controller.dart';

class FakeApi extends ApiClient {
  FakeApi() : super(baseUrl: 'http://fake.test');

  final List<Map<String, dynamic>> created = [];

  /// When set, createTimeEntry throws it instead of succeeding.
  ApiException? failWith;

  @override
  Future<TimeEntry> createTimeEntry(int workspaceId, Map<String, dynamic> payload) async {
    if (failWith != null) throw failWith!;
    created.add(payload);
    return TimeEntry.fromJson({
      'id': created.length,
      'projectId': payload['projectId'],
      'taskTitle': payload['taskTitle'],
      'date': payload['date'],
      'billable': payload['billable'],
    });
  }
}

const _user = User(id: 64, email: 'e@x.test', name: 'Edgar P', role: 'user');
const _workspace = Workspace(
  id: 36,
  name: 'STDev',
  timezone: 'Asia/Yerevan',
  memberCount: 1,
  projectCount: 1,
  myRole: 'member',
);
const _css = Project(
  id: 38,
  name: 'CSS',
  color: Color(0xFF10B981),
  status: 'active',
);

void main() {
  late FakeApi api;
  late AppStorage storage;
  late DateTime now;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = AppStorage(await SharedPreferences.getInstance());
    api = FakeApi();
    now = DateTime(2026, 10, 7, 12, 0, 0);
  });

  TrackerController make({VoidCallback? onSaved}) => TrackerController(
        api: api,
        storage: storage,
        user: _user,
        workspace: _workspace,
        onEntrySaved: onSaved,
        now: () => now,
      );

  TrackerController filled() => make()
    ..setProject(_css)
    ..setTaskTitle('CDEV-1');

  void advance(Duration d) => now = now.add(d);

  group('stopwatch', () {
    test('counts from the moment Start is pressed', () {
      final t = filled();
      expect(t.start(), isNull);
      expect(t.elapsed, Duration.zero);
      advance(const Duration(minutes: 10));
      expect(t.elapsed, const Duration(minutes: 10));
    });

    test('pause freezes time and resume continues it', () {
      final t = filled()..start();
      advance(const Duration(minutes: 10));
      t.pause();
      advance(const Duration(minutes: 5));
      expect(t.elapsed, const Duration(minutes: 10));
      expect(t.phase, TimerPhase.paused);

      t.resume();
      advance(const Duration(minutes: 2));
      expect(t.elapsed, const Duration(minutes: 12));
      expect(t.phase, TimerPhase.running);
    });

    test('an earlier start time counts from that moment', () {
      final t = filled()..setStartTime(const TimeOfDay(hour: 11, minute: 30));
      expect(t.start(), isNull);
      expect(t.elapsed, const Duration(minutes: 30));
      advance(const Duration(minutes: 1));
      expect(t.elapsed, const Duration(minutes: 31));
    });

    test('a future start time is refused and the timer stays idle', () {
      final t = filled()..setStartTime(const TimeOfDay(hour: 13, minute: 0));
      expect(t.start(), contains('future'));
      expect(t.phase, TimerPhase.idle);
    });

    test('a past date needs an explicit start time', () {
      final t = filled()..setDate(DateTime(2026, 10, 5));
      expect(t.start(), isNotNull);
      expect(t.phase, TimerPhase.idle);

      t.setStartTime(const TimeOfDay(hour: 9, minute: 0));
      expect(t.start(), isNull);
      expect(t.startedAt, DateTime(2026, 10, 5, 9, 0));
    });
  });

  group('keeping on this Mac', () {
    test('end(upload: false) stores the entry locally without uploading', () async {
      final t = filled()..start();
      advance(const Duration(minutes: 45));

      expect(await t.end(upload: false), EndOutcome.keptLocally);
      expect(api.created, isEmpty);
      expect(t.pending, isEmpty);
      expect(t.local.single.minutes, 45);
      expect(t.local.single.taskTitle, 'CDEV-1');
      expect(t.phase, TimerPhase.idle);

      // Survives a restart.
      expect(make().local.single.id, t.local.single.id);
    });

    test('uploadLocal sends it and removes it once accepted', () async {
      var saved = 0;
      final t = make(onSaved: () => saved++)
        ..setProject(_css)
        ..setTaskTitle('CDEV-1')
        ..start();
      advance(const Duration(minutes: 30));
      await t.end(upload: false);

      api.failWith = const ApiException('Server down');
      expect(await t.uploadLocal(t.local.single.id), 'Server down');
      expect(t.local, hasLength(1));

      api.failWith = null;
      expect(await t.uploadLocal(t.local.single.id), isNull);
      expect(t.local, isEmpty);
      expect(api.created.single['minutes'], 30);
      expect(saved, 1);
      expect(make().local, isEmpty);
    });

    test('updateLocal edits it in place and keeps it across restarts', () async {
      final t = filled()..start();
      advance(const Duration(minutes: 40));
      await t.end(upload: false);
      final id = t.local.single.id;

      t.updateLocal(id, {
        ...t.local.single.payload,
        'taskTitle': 'Renamed',
        'hours': 1,
        'minutes': 5,
      }, projectName: 'CSS');

      expect(t.local.single.id, id);
      expect(t.local.single.taskTitle, 'Renamed');
      expect(t.local.single.minutes, 65);
      expect(make().local.single.taskTitle, 'Renamed');
    });

    test('restoreLocal undoes a delete in place', () async {
      final t = filled()..start();
      advance(const Duration(minutes: 10));
      await t.end(upload: false);
      t
        ..setTaskTitle('Second')
        ..start();
      advance(const Duration(minutes: 5));
      await t.end(upload: false);
      final first = t.local.first;

      t.deleteLocal(first.id);
      t.restoreLocal(first, 0);
      t.restoreLocal(first, 0); // A second Undo is ignored.
      expect(t.local.map((e) => e.taskTitle), ['CDEV-1', 'Second']);
    });

    test('deleteLocal drops it without uploading', () async {
      final t = filled()..start();
      advance(const Duration(minutes: 10));
      await t.end(upload: false);
      t.deleteLocal(t.local.single.id);
      expect(t.local, isEmpty);
      expect(api.created, isEmpty);
      expect(make().local, isEmpty);
    });
  });

  group('ending', () {
    test('uploads exactly the payload the API expects', () async {
      final t = make()
        ..setProject(_css)
        ..setTaskTitle('  CDEV-2228 ')
        ..setDescription('Pay Now Functional')
        ..toggleTag(101)
        ..toggleTag(88)
        ..setBillable(false)
        ..start();
      advance(const Duration(hours: 1, minutes: 30));

      expect(await t.end(), EndOutcome.saved);
      expect(api.created.single, {
        'projectId': 38,
        'taskTitle': 'CDEV-2228',
        'description': 'Pay Now Functional',
        'hours': 1,
        'minutes': 30,
        'date': '2026-10-07',
        'billable': false,
        'tagIds': [88, 101],
      });
      expect(t.pending, isEmpty);
    });

    test('sends a null description when blank', () async {
      final t = filled()..start();
      advance(const Duration(minutes: 5));
      await t.end();
      expect(api.created.single['description'], isNull);
      expect(api.created.single['tagIds'], isEmpty);
    });

    test('resets the form for the next entry but keeps project and billable', () async {
      final t = filled()
        ..setDescription('d')
        ..toggleTag(1)
        ..setBillable(false)
        ..start();
      advance(const Duration(minutes: 5));
      await t.end();

      expect(t.phase, TimerPhase.idle);
      expect(t.taskTitle, isEmpty);
      expect(t.description, isEmpty);
      expect(t.tagIds, isEmpty);
      expect(t.projectId, 38);
      expect(t.billable, isFalse);
    });

    test('notifies the app after each saved entry', () async {
      var saved = 0;
      final t = make(onSaved: () => saved++)
        ..setProject(_css)
        ..setTaskTitle('x')
        ..start();
      advance(const Duration(minutes: 5));
      await t.end();
      expect(saved, 1);
    });

    test('rounds to the nearest minute', () async {
      final t = filled()..start();
      advance(const Duration(seconds: 90));
      await t.end();
      expect(api.created.single['minutes'], 2);
    });

    test('under 30 seconds is not uploaded and the timer is kept', () async {
      final t = filled()..start();
      advance(const Duration(seconds: 20));
      expect(await t.end(), EndOutcome.tooShort);
      expect(api.created, isEmpty);
      expect(t.phase, TimerPhase.running);
      expect(t.elapsed, const Duration(seconds: 20));
    });

    test('under a minute can be kept on this Mac, then uploaded as 1 minute', () async {
      final t = filled()..start();
      advance(const Duration(seconds: 20));
      expect(await t.end(upload: false), EndOutcome.keptLocally);
      expect(t.phase, TimerPhase.idle);
      final entry = t.local.single;
      expect(entry.seconds, 20);
      expect(entry.minutes, 0);
      expect(entry.underAMinute, isTrue);
      expect(make().local.single.seconds, 20);

      expect(await t.uploadLocal(entry.id), isNull);
      expect(api.created.single['hours'], 0);
      expect(api.created.single['minutes'], 1);
    });

    test('more than 24h is split across days', () async {
      final t = filled()..start();
      advance(const Duration(hours: 25, minutes: 30));
      expect(await t.end(), EndOutcome.saved);
      expect(api.created.map((p) => [p['date'], p['hours'], p['minutes']]), [
        ['2026-10-07', 24, 0],
        ['2026-10-08', 1, 30],
      ]);
    });

    test('a blank title keeps the timer running', () async {
      final t = filled()..start();
      advance(const Duration(minutes: 5));
      t.setTaskTitle('   ');
      expect(await t.end(), EndOutcome.invalid);
      expect(t.invalidReason, contains('title'));
      expect(t.phase, TimerPhase.running);
      expect(api.created, isEmpty);
    });
  });

  group('failed uploads', () {
    test('stay queued, report the error, and can be retried', () async {
      api.failWith = const ApiException('Server exploded', statusCode: 500);
      final t = filled()..start();
      advance(const Duration(minutes: 45));

      expect(await t.end(), EndOutcome.failed);
      expect(t.pending, hasLength(1));
      expect(t.pending.single.minutes, 45);
      expect(t.saveError, 'Server exploded');
      expect(t.phase, TimerPhase.idle);

      api.failWith = null;
      expect(await t.flushPending(), isTrue);
      expect(t.pending, isEmpty);
      expect(t.saveError, isNull);
      expect(api.created.single['minutes'], 45);
    });

    test('survive an app restart', () async {
      api.failWith = const ApiException('offline', isNetwork: true);
      final t = filled()..start();
      advance(const Duration(minutes: 20));
      await t.end();

      final restarted = make();
      expect(restarted.pending, hasLength(1));
      expect(restarted.pending.single.projectName, 'CSS');

      api.failWith = null;
      expect(await restarted.flushPending(), isTrue);
      expect(api.created.single['minutes'], 20);
      expect(make().pending, isEmpty);
    });

    test('can be discarded', () async {
      api.failWith = const ApiException('nope', statusCode: 400);
      final t = filled()..start();
      advance(const Duration(minutes: 5));
      await t.end();
      t.discardPending();
      expect(t.pending, isEmpty);
      expect(t.saveError, isNull);
    });
  });

  group('persistence', () {
    test('a running timer survives a restart and keeps counting', () {
      final t = filled()
        ..setDescription('notes')
        ..toggleTag(5)
        ..start();
      advance(const Duration(minutes: 3));

      final restarted = make();
      expect(restarted.phase, TimerPhase.running);
      expect(restarted.elapsed, const Duration(minutes: 3));
      expect(restarted.taskTitle, 'CDEV-1');
      expect(restarted.description, 'notes');
      expect(restarted.tagIds, {5});
      expect(restarted.projectName, 'CSS');

      advance(const Duration(minutes: 2));
      expect(restarted.elapsed, const Duration(minutes: 5));
      expect(t.elapsed, const Duration(minutes: 5));
    });

    test('a paused timer stays paused across a restart', () {
      final t = filled()..start();
      advance(const Duration(minutes: 7));
      t.pause();

      advance(const Duration(hours: 3));
      final restarted = make();
      expect(restarted.phase, TimerPhase.paused);
      expect(restarted.elapsed, const Duration(minutes: 7));
    });

    test('state is separate per workspace', () {
      filled().start();
      final other = TrackerController(
        api: api,
        storage: storage,
        user: _user,
        workspace: const Workspace(
          id: 99,
          name: 'Other',
          timezone: 'UTC',
          memberCount: 1,
          projectCount: 1,
          myRole: 'member',
        ),
        now: () => now,
      );
      expect(other.phase, TimerPhase.idle);
    });

    test('corrupt saved state does not crash', () async {
      SharedPreferences.setMockInitialValues({'tracker.v1.64.36': '{"phase":"running","startedAt":"garbage"}'});
      storage = AppStorage(await SharedPreferences.getInstance());
      final t = make();
      expect(t.phase, TimerPhase.idle);
    });
  });

  test('discard throws the timer away without a request', () {
    final t = filled()..start();
    advance(const Duration(minutes: 30));
    t.discard();
    expect(t.phase, TimerPhase.idle);
    expect(t.elapsed, Duration.zero);
    expect(api.created, isEmpty);
  });
}
