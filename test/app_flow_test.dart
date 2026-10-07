import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timmy/app.dart';
import 'package:timmy/core/api_client.dart';
import 'package:timmy/core/storage.dart';
import 'package:timmy/features/tracker/tracker_page.dart';
import 'package:timmy/models/models.dart';
import 'package:timmy/widgets/timmy_logo.dart';
import 'package:timmy/state/tracker_controller.dart';

import 'support/fake_backend.dart';

void main() {
  late FakeBackend backend;
  late AppStorage storage;

  // Pinned so tracked durations are exact rather than "90 minutes plus a few
  // real seconds".
  final fixedNow = DateTime(2026, 10, 7, 12, 0, 0);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = AppStorage(await SharedPreferences.getInstance());
    backend = FakeBackend();
  });

  Future<void> launch(WidgetTester tester) async {
    // The app's default compact window size.
    tester.view.physicalSize = const Size(380, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = ApiClient(baseUrl: 'https://api.test', httpClient: backend.client);
    await tester.pumpWidget(TimmyApp(api: api, storage: storage, clock: () => fixedNow));
    await tester.pumpAndSettle();
  }

  /// Disposes the app so periodic timers (token refresh, clock) are cancelled.
  Future<void> shutDown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
  }

  Future<void> signIn(WidgetTester tester) async {
    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), demoEmail);
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), demoPassword);
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
  }

  testWidgets('login rejects bad credentials with the server message', (tester) async {
    await launch(tester);
    expect(find.text('Sign in to track your time'), findsOneWidget);
    expect(find.byType(TimmyLogo), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), demoEmail);
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'wrong');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Invalid credentials'), findsOneWidget);
    expect(find.text('Choose a workspace'), findsNothing);
    await shutDown(tester);
  });

  testWidgets('login validates empty fields before calling the API', (tester) async {
    await launch(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Enter your email'), findsOneWidget);
    expect(find.text('Enter your password'), findsOneWidget);
    expect(backend.requests, isEmpty);
    await shutDown(tester);
  });

  testWidgets('sign in → workspaces → track time → entry is saved', (tester) async {
    await launch(tester);
    await signIn(tester);

    // Workspace list.
    expect(find.text('Choose a workspace'), findsOneWidget);
    expect(find.text('STDev'), findsOneWidget);
    expect(find.textContaining('49 members · 34 projects'), findsOneWidget);
    await tester.tap(find.text('STDev'));
    await tester.pumpAndSettle();

    // Tracker with the data requested for the right user/workspace.
    expect(find.text('Tracker'), findsOneWidget);
    expect(backend.requests, containsAll([
      'GET /api/workspaces/36/projects?memberId=64',
      'GET /api/workspaces/36/tags',
      'GET /api/workspaces/36/time-entries?userId=64',
    ]));

    // Starting without filling in the form is blocked.
    await tester.tap(find.byTooltip('Start'));
    await tester.pumpAndSettle();
    expect(find.text('Select a project'), findsWidgets);
    expect(find.text('Enter a task title'), findsOneWidget);
    expect(find.byTooltip('End & save'), findsNothing);

    // Fill in the form.
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CSS').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Task title'), 'CDEV-2228');
    await tester.enterText(find.widgetWithText(TextFormField, 'Description (optional)'), 'Pay Now Functional');
    await tester.ensureVisible(find.widgetWithText(FilterChip, 'Call'));
    await tester.tap(find.widgetWithText(FilterChip, 'Call'));
    await tester.pump();

    // The work started at 10:30; it is 12:00 now.
    final tracker = tester.element(find.byType(TrackerPage)).read<TrackerController>();
    tracker.setStartTime(const TimeOfDay(hour: 10, minute: 30));
    await tester.pump();

    await tester.tap(find.byTooltip('Start'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byTooltip('Pause'), findsOneWidget);
    expect(find.byTooltip('End & save'), findsOneWidget);
    expect(find.text('01:30:00'), findsOneWidget);

    // Pause and resume work.
    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
    expect(find.byTooltip('Resume'), findsOneWidget);
    await tester.tap(find.byTooltip('Resume'));
    await tester.pump();

    // End → exactly one POST with the right body.
    await tester.tap(find.byTooltip('End & save'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    final posted = backend.postedEntries.single;
    expect(posted['projectId'], 38);
    expect(posted['taskTitle'], 'CDEV-2228');
    expect(posted['description'], 'Pay Now Functional');
    expect(posted['hours'], 1);
    expect(posted['minutes'], 30);
    expect(posted['date'], '2026-10-07');
    expect(posted['billable'], true);
    expect(posted['tagIds'], [101]);
    expect(find.text('Saved 1h 30m to CSS'), findsOneWidget);
    expect(find.byTooltip('Start'), findsOneWidget);

    // The new entry shows up on the Time entries page.
    await tester.tap(find.text('Entries'));
    await tester.pumpAndSettle();
    expect(find.text('CDEV-2228'), findsNWidgets(2));
    expect(find.text('1h 30m'), findsWidgets);

    await shutDown(tester);
  });

  testWidgets('a title error clears as soon as the user types a title', (tester) async {
    await launch(tester);
    await signIn(tester);
    await tester.tap(find.text('STDev'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Start'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a task title'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextFormField, 'Task title'), 'Now it has a title');
    await tester.pumpAndSettle();
    expect(find.text('Enter a task title'), findsNothing);
    await shutDown(tester);
  });

  testWidgets('a failed save is kept, shown, and can be retried', (tester) async {
    await launch(tester);
    await signIn(tester);
    await tester.tap(find.text('STDev'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CSS').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Task title'), 'Flaky upload');

    final tracker = tester.element(find.byType(TrackerPage)).read<TrackerController>();
    tracker.setStartTime(const TimeOfDay(hour: 11, minute: 15));
    await tester.tap(find.byTooltip('Start'));
    await tester.pump(const Duration(milliseconds: 100));

    backend.failEntryPosts = true;
    await tester.tap(find.byTooltip('End & save'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining("Couldn't save 45m"), findsOneWidget);
    expect(find.textContaining('Something went wrong'), findsOneWidget);
    expect(backend.postedEntries, isEmpty);

    backend.failEntryPosts = false;
    await tester.tap(find.text('Retry'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(backend.postedEntries.single['minutes'], 45);
    expect(find.textContaining("Couldn't save"), findsNothing);
    await shutDown(tester);
  });

  testWidgets('a saved session reopens the last workspace and keeps a running timer', (tester) async {
    await storage.saveToken('tokenString');
    await storage.saveUser(User.fromJson(demoUser));
    await storage.saveSelectedWorkspace(36);
    final began = fixedNow.subtract(const Duration(minutes: 20));
    await storage.saveTrackerState(64, 36, {
      'projectId': 38,
      'projectName': 'CSS',
      'taskTitle': 'Resumed after restart',
      'description': '',
      'tagIds': <int>[],
      'billable': true,
      'phase': 'running',
      'startedAt': began.toIso8601String(),
      'accumulatedMs': 0,
      'resumedAt': began.toIso8601String(),
      'pending': <Map<String, dynamic>>[],
    });

    await launch(tester);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Choose a workspace'), findsNothing);
    expect(find.text('Resumed after restart'), findsOneWidget);
    expect(find.text('00:20:00'), findsOneWidget);
    expect(find.byTooltip('End & save'), findsOneWidget);
    await shutDown(tester);
  });

  testWidgets('an expired session returns to login with a notice', (tester) async {
    await storage.saveToken('stale-token');
    await launch(tester);

    expect(find.text('Sign in to track your time'), findsOneWidget);
    expect(find.text('Your session expired. Please sign in again.'), findsOneWidget);
    await shutDown(tester);
  });
}
