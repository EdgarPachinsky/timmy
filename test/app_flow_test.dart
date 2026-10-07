import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timmy/app.dart';
import 'package:timmy/core/api_client.dart';
import 'package:timmy/core/jira_client.dart';
import 'package:timmy/core/storage.dart';
import 'package:timmy/core/trello_client.dart';
import 'package:timmy/features/shell/user_menu.dart';
import 'package:timmy/features/tracker/tracker_page.dart';
import 'package:timmy/models/models.dart';
import 'package:timmy/widgets/timmy_logo.dart';
import 'package:timmy/state/jira_controller.dart';
import 'package:timmy/state/tracker_controller.dart';
import 'package:timmy/state/trello_controller.dart';

import 'models_test.dart' show projectWithoutClient;
import 'support/fake_backend.dart';
import 'support/fake_trello.dart';

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
    tester.view.physicalSize = const Size(344, 770);
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

  /// Presses End and picks [choice] from its menu.
  Future<void> endTimer(WidgetTester tester, String choice) async {
    await tester.tap(find.byTooltip('End'));
    await tester.pump();
    await tester.tap(find.text(choice));
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
    expect(find.byTooltip('End'), findsNothing);

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
    expect(find.byTooltip('End'), findsOneWidget);
    expect(find.text('01:30:00'), findsOneWidget);

    // Pause and resume work.
    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
    expect(find.byTooltip('Resume'), findsOneWidget);
    await tester.tap(find.byTooltip('Resume'));
    await tester.pump();

    // End → exactly one POST with the right body.
    await endTimer(tester, 'Save to Time-Wise');
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
    expect(find.text('Enter a task title'), findsNothing);
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
    await endTimer(tester, 'Save to Time-Wise');
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
    expect(find.byTooltip('End'), findsOneWidget);
    await shutDown(tester);
  });

  testWidgets('an entry kept on this Mac is uploaded later from Entries', (tester) async {
    await launch(tester);
    await signIn(tester);
    await tester.tap(find.text('STDev'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CSS').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Task title'), 'Offline work');

    final tracker = tester.element(find.byType(TrackerPage)).read<TrackerController>();
    tracker.setStartTime(const TimeOfDay(hour: 11, minute: 0));
    await tester.tap(find.byTooltip('Start'));
    await tester.pump(const Duration(milliseconds: 100));

    // Opening End stops the clock; closing the menu without a choice restarts it.
    await tester.tap(find.byTooltip('End'));
    await tester.pump();
    expect(tracker.isRunning, isFalse);
    expect(find.text('Keep on this Mac'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump();
    expect(find.text('Keep on this Mac'), findsNothing);
    expect(tracker.isRunning, isTrue);

    await endTimer(tester, 'Keep on this Mac');
    await tester.pump(const Duration(milliseconds: 100));
    expect(tracker.isActive, isFalse);
    expect(backend.postedEntries, isEmpty);
    expect(find.textContaining('Kept 1h on this Mac'), findsOneWidget);
    expect(find.text('Enter a task title'), findsNothing);
    expect(find.byTooltip('Start'), findsOneWidget);

    await tester.tap(find.text('Entries'));
    await tester.pumpAndSettle();
    expect(find.text('Offline work'), findsOneWidget);
    expect(find.text('Only on this Mac'), findsOneWidget);
    expect(find.byTooltip('Saved in Time-Wise'), findsOneWidget); // The existing server entry.

    await tester.tap(find.byTooltip('Upload to Time-Wise'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(backend.postedEntries.single['taskTitle'], 'Offline work');
    expect(backend.postedEntries.single['hours'], 1);

    await tester.pumpAndSettle();
    expect(find.text('Only on this Mac'), findsNothing);
    await shutDown(tester);
  });

  testWidgets('a Time-Wise entry can be edited from Entries', (tester) async {
    await launch(tester);
    await signIn(tester);
    await tester.tap(find.text('STDev'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Entries'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('CDEV-2228'));
    await tester.pumpAndSettle();
    expect(find.text('Edit entry'), findsOneWidget);
    expect(find.text('In Time-Wise'), findsOneWidget);

    Finder field(String label) => find.descendant(
          of: find.byType(Dialog),
          matching: find.widgetWithText(TextFormField, label),
        );
    await tester.enterText(field('Task title'), 'CDEV-2228 edited');
    await tester.enterText(field('Hours'), '7');
    await tester.enterText(field('Minutes'), '15');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final update = backend.updatedEntries.single;
    expect(update['id'], 143);
    expect(update['taskTitle'], 'CDEV-2228 edited');
    expect(update['hours'], 7);
    expect(update['minutes'], 15);
    expect(update['projectId'], 38);
    expect(update['date'], '2026-06-29');
    expect(find.text('Edit entry'), findsNothing);
    expect(find.text('Entry updated.'), findsOneWidget);
    expect(find.text('CDEV-2228 edited'), findsOneWidget);
    expect(find.text('7h 15m'), findsWidgets);
    await shutDown(tester);
  });

  testWidgets('a Time-Wise entry can be deleted from the editor', (tester) async {
    await launch(tester);
    await signIn(tester);
    await tester.tap(find.text('STDev'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Entries'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('CDEV-2228'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete')); // The editor's footer button.
    await tester.pumpAndSettle();
    expect(find.text('Delete from Time-Wise?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(backend.deletedEntryIds, [143]);
    expect(find.text('Edit entry'), findsNothing);
    expect(find.text('Entry deleted.'), findsOneWidget);
    expect(find.text('CDEV-2228'), findsNothing);
    await shutDown(tester);
  });

  testWidgets('the row trash icon deletes after a confirmation, and Undo brings it back', (tester) async {
    await launch(tester);
    await signIn(tester);
    await tester.tap(find.text('STDev'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Entries'));
    await tester.pumpAndSettle();

    // Cancel keeps it.
    await tester.tap(find.byTooltip('Delete from Time-Wise'));
    await tester.pumpAndSettle();
    expect(find.text('Delete from Time-Wise?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(backend.deletedEntryIds, isEmpty);
    expect(find.text('CDEV-2228'), findsOneWidget);

    await tester.tap(find.byTooltip('Delete from Time-Wise'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(backend.deletedEntryIds, [143]);
    expect(find.text('CDEV-2228'), findsNothing);
    expect(find.text('Deleted "CDEV-2228" from Time-Wise.'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    final restored = backend.postedEntries.single;
    expect(restored['taskTitle'], 'CDEV-2228');
    expect(restored['description'], 'Pay Now Functional');
    expect(restored['hours'], 8);
    expect(restored['date'], '2026-06-29');
    expect(find.text('CDEV-2228'), findsOneWidget);
    await shutDown(tester);
  });

  testWidgets('the editor refuses an empty duration', (tester) async {
    await launch(tester);
    await signIn(tester);
    await tester.tap(find.text('STDev'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Entries'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CDEV-2228'));
    await tester.pumpAndSettle();

    final hours = find.descendant(of: find.byType(Dialog), matching: find.widgetWithText(TextFormField, 'Hours'));
    await tester.enterText(hours, '0');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Enter at least 1 minute.'), findsOneWidget);
    expect(backend.updatedEntries, isEmpty);
    await shutDown(tester);
  });

  testWidgets('Projects opens from the top bar and Track preselects the project', (tester) async {
    await launch(tester);
    await signIn(tester);
    await tester.tap(find.text('STDev'));
    await tester.pumpAndSettle();

    // Tracker, Plan and Entries tabs; Projects lives in the top bar.
    expect(find.text('Tracker'), findsOneWidget);
    expect(find.text('Plan'), findsOneWidget);
    expect(find.text('Entries'), findsOneWidget);

    await tester.tap(find.byTooltip('Projects'));
    await tester.pumpAndSettle();
    expect(find.text('Projects'), findsOneWidget); // The page title.

    final cssTile = find.ancestor(of: find.text('CSS'), matching: find.byType(Card));
    await tester.tap(find.descendant(of: cssTile, matching: find.byTooltip('Track')));
    await tester.pumpAndSettle();

    expect(find.text('Projects'), findsNothing);
    final tracker = tester.element(find.byType(TrackerPage)).read<TrackerController>();
    expect(tracker.projectId, 38);
    await shutDown(tester);
  });

  testWidgets('a day over 8h shows its overtime, across projects', (tester) async {
    // 8h on CSS already that day; 1h 30m more on another project.
    backend.entries.add({
      'id': 145,
      'workspaceId': 36,
      'projectId': 62,
      'userId': 64,
      'taskTitle': 'Evening fixes',
      'hours': 1,
      'minutes': 30,
      'totalMinutes': 90,
      'date': '2026-06-29',
      'billable': true,
      'project': projectWithoutClient,
      'tags': <Map<String, dynamic>>[],
      'createdAt': '2026-06-29T18:00:00.000Z',
    });
    await launch(tester);
    await signIn(tester);
    await tester.tap(find.text('STDev'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Entries'));
    await tester.pumpAndSettle();

    expect(find.text('+1h 30m overtime'), findsOneWidget);
    expect(find.textContaining('Overtime · '), findsOneWidget);

    // Filtering to one project still shows the day's real overtime.
    await tester.tap(find.text('All projects'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CSS').last);
    await tester.pumpAndSettle();
    expect(find.text('+1h 30m overtime'), findsOneWidget);
    await shutDown(tester);
  });

  testWidgets('Jira tasks opens from the avatar menu once Jira is connected', (tester) async {
    final moves = <Map<String, dynamic>>[];
    final jiraClient = JiraClient(httpClient: MockClient((req) async {
      http.Response json(Object body) => http.Response(
            jsonEncode(body),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
      if (req.url.path.endsWith('/transitions')) {
        if (req.method == 'POST') {
          moves.add(jsonDecode(req.body) as Map<String, dynamic>);
          return http.Response('', 204);
        }
        return json({
          'transitions': [
            {
              'id': '11',
              'name': 'Back to work',
              'to': {'name': 'In Progress', 'statusCategory': {'key': 'indeterminate'}},
            },
          ],
        });
      }
      Map<String, dynamic> issue(String key, String summary, String description) => {
            'key': key,
            'fields': {
              'summary': summary,
              'description': description,
              'status': {'name': 'Ready for Test', 'statusCategory': {'key': 'indeterminate'}},
              'priority': {'name': 'High'},
            },
          };
      return http.Response(
        jsonEncode({
          'issues': [
            issue('CDEV-2480', 'Canvas Save and Edit', 'Save Canvas Layout. Positions are kept.'),
            issue('CDEV-2449', 'UDW List', 'The list view is second in the sidebar. Figma: https://figma.com/file/udw'),
          ],
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }));

    tester.view.physicalSize = const Size(344, 770);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = ApiClient(baseUrl: 'https://api.test', httpClient: backend.client);
    await tester.pumpWidget(TimmyApp(api: api, storage: storage, clock: () => fixedNow, jira: jiraClient));
    await tester.pumpAndSettle();
    await signIn(tester);
    await tester.tap(find.text('STDev'));
    await tester.pumpAndSettle();

    // Not connected yet: no Jira item.
    await tester.tap(find.byType(UserMenu));
    await tester.pumpAndSettle();
    expect(find.text('Jira tasks'), findsNothing);
    await tester.tapAt(const Offset(10, 600)); // Close the menu.
    await tester.pumpAndSettle();

    final jira = tester.element(find.byType(TrackerPage)).read<JiraController>();
    await tester.runAsync(() => jira.connect(site: 'acme', email: 'me@acme.test', apiToken: 't'));
    await tester.pump();

    await tester.tap(find.byType(UserMenu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Jira tasks'));
    await tester.pumpAndSettle();
    expect(find.text('Canvas Save and Edit'), findsOneWidget);
    expect(find.text('UDW List'), findsOneWidget);

    // "Contains" search, inside a word of the description.
    await tester.enterText(find.byType(TextField).first, 'idebar');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('UDW List'), findsOneWidget);
    expect(find.text('Canvas Save and Edit'), findsNothing);

    await tester.tap(find.text('UDW List'));
    await tester.pumpAndSettle();
    expect(find.textContaining('The list view is second in the sidebar.', findRichText: true), findsOneWidget);
    expect(find.byIcon(Icons.open_in_new), findsWidgets); // The Figma link, and Open in Jira.
    expect(find.text('CDEV-2449'), findsWidgets);
    expect(find.text('High'), findsWidgets);

    // Move it to another column from the status pill.
    await tester.tap(find.byTooltip('Move to another column'));
    await tester.pumpAndSettle();
    expect(find.text('Move CDEV-2449 to'), findsOneWidget);
    await tester.tap(find.text('In Progress'));
    await tester.pumpAndSettle();
    expect(moves.single, {
      'transition': {'id': '11'},
    });
    expect(find.text('Moved CDEV-2449 to In Progress.'), findsOneWidget);
    await shutDown(tester);
  });

  testWidgets('Plan ranks Jira tasks and Start begins tracking the task', (tester) async {
    final jiraClient = JiraClient(httpClient: MockClient((req) async {
      Map<String, dynamic> issue(String key, String summary, String status, String category, String priority) => {
            'key': key,
            'fields': {
              'summary': summary,
              'status': {'name': status, 'statusCategory': {'key': category}},
              'priority': {'name': priority},
              'issuetype': {'name': 'Task'},
            },
          };
      return http.Response(
        jsonEncode({
          'issues': [
            issue('CDEV-77', 'Low priority chore', 'To Do', 'new', 'Low'),
            issue('CDEV-2228', 'Pay Now flow', 'In Progress', 'indeterminate', 'High'),
            issue('CDEV-90', 'Waiting for QA', 'Ready for Test', 'indeterminate', 'High'),
          ],
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }));

    tester.view.physicalSize = const Size(344, 770);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = ApiClient(baseUrl: 'https://api.test', httpClient: backend.client);
    await tester.pumpWidget(TimmyApp(api: api, storage: storage, clock: () => fixedNow, jira: jiraClient));
    await tester.pumpAndSettle();
    await signIn(tester);
    await tester.tap(find.text('STDev'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    expect(find.text('Connect Jira'), findsOneWidget);

    final jira = tester.element(find.byType(TrackerPage)).read<JiraController>();
    await tester.runAsync(() => jira.connect(site: 'acme', email: 'me@acme.test', apiToken: 't'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('Plan for today'), findsOneWidget);
    // In progress + High first; the QA task is set apart (collapsed).
    final payNow = tester.getTopLeft(find.text('Pay Now flow'));
    final chore = tester.getTopLeft(find.text('Low priority chore'));
    expect(payNow.dy, lessThan(chore.dy));
    expect(find.text('Waiting on review / test'), findsOneWidget);
    expect(find.text('Waiting for QA'), findsNothing);
    expect(find.text('Write standup'), findsOneWidget);

    // CDEV-2228 was last tracked on CSS, so Start goes straight to a running timer.
    await tester.tap(find.byTooltip('Start CDEV-2228'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final tracker = tester.element(find.byType(TrackerPage)).read<TrackerController>();
    expect(tracker.isRunning, isTrue);
    expect(tracker.projectId, 38);
    expect(tracker.taskTitle, 'CDEV-2228 Pay Now flow');
    expect(find.byTooltip('End'), findsOneWidget);
    expect(find.text('CDEV-2228 Pay Now flow'), findsOneWidget); // In the title field.
    await shutDown(tester);
  });

  testWidgets('a Trello card can be picked as the task title', (tester) async {
    final trelloApi = FakeTrello();
    final jiraClient = JiraClient(httpClient: MockClient((req) async => http.Response(
          jsonEncode({'accountId': 'a1', 'displayName': 'Edgar P', 'issues': <Object>[]}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        )));
    tester.view.physicalSize = const Size(344, 770);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = ApiClient(baseUrl: 'https://api.test', httpClient: backend.client);
    await tester.pumpWidget(TimmyApp(
      api: api,
      storage: storage,
      clock: () => fixedNow,
      jira: jiraClient,
      trello: TrelloClient(httpClient: trelloApi.client),
    ));
    await tester.pumpAndSettle();
    await signIn(tester);
    await tester.tap(find.text('STDev'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Connect Jira or Trello to pick tasks'), findsOneWidget);

    final trello = tester.element(find.byType(TrackerPage)).read<TrelloController>();
    await tester.runAsync(() => trello.connect(apiKey: 'k123', token: 't456'));
    await tester.pump();

    // Only Trello connected: straight into the card picker.
    await tester.tap(find.byTooltip('Pick a Trello card'));
    await tester.pumpAndSettle();
    expect(find.text('Trello cards'), findsOneWidget);
    expect(find.text('Ops · Backlog'), findsOneWidget);
    expect(find.text('Product · Doing'), findsOneWidget);
    // The card's label (the tracker behind also has a 'Bug' tag chip).
    expect(find.descendant(of: find.byType(Dialog), matching: find.text('Bug')), findsOneWidget);

    await tester.enterText(find.descendant(of: find.byType(Dialog), matching: find.byType(TextField)), 'overlaps');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.text('Rotate server keys'), findsNothing);
    await tester.tap(find.text('Fix checkout button'));
    await tester.pumpAndSettle();

    final tracker = tester.element(find.byType(TrackerPage)).read<TrackerController>();
    expect(tracker.taskTitle, 'Fix checkout button');
    expect(find.text('Fix checkout button'), findsOneWidget); // in the title field

    // With Jira connected too, the button asks which to pick from.
    final jira = tester.element(find.byType(TrackerPage)).read<JiraController>();
    await tester.runAsync(() => jira.connect(site: 'acme', email: 'me@acme.test', apiToken: 't'));
    await tester.pump();
    await tester.tap(find.byTooltip('Pick a Jira task or Trello card'));
    await tester.pumpAndSettle();
    expect(find.text('Jira tasks'), findsOneWidget);
    expect(find.text('Trello cards'), findsOneWidget);
    await tester.tapAt(const Offset(10, 700)); // dismiss
    await tester.pumpAndSettle();
    await shutDown(tester);
  });

  testWidgets('entries can be filtered by project, with month totals', (tester) async {
    backend.entries.add({
      'id': 144,
      'workspaceId': 36,
      'projectId': 62,
      'userId': 64,
      'taskTitle': 'Other project work',
      'hours': 0,
      'minutes': 45,
      'totalMinutes': 45,
      'date': '2026-10-07',
      'billable': false,
      'project': projectWithoutClient,
      'tags': <Map<String, dynamic>>[],
      'createdAt': '2026-10-07T09:00:00.000Z',
    });
    await launch(tester);
    await signIn(tester);
    await tester.tap(find.text('STDev'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Entries'));
    await tester.pumpAndSettle();

    expect(find.text('This month'), findsOneWidget);
    expect(find.text('CDEV-2228'), findsOneWidget);
    expect(find.text('Other project work'), findsOneWidget);

    await tester.tap(find.text('All projects'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CSS').last);
    await tester.pumpAndSettle();

    expect(find.text('CDEV-2228'), findsOneWidget);
    expect(find.text('Other project work'), findsNothing);
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
