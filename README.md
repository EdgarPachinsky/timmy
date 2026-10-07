# Timmy

A small macOS time tracker for [Time-Wise](https://time-wise.codebnb.me) workspaces, in the spirit of
Upwork's time tracker. Built with Flutter (Dart).

## Run

```bash
flutter pub get
flutter run -d macos
```

Point it at a different backend (e.g. a local one) with a compile-time define:

```bash
flutter run -d macos --dart-define=API_BASE_URL=http://127.0.0.1:8787
```

Tests and analysis:

```bash
flutter analyze
flutter test
```

## What it does

Timmy runs in a compact window (380×640 by default, resizable down to 340×480) with a top bar
(workspace, switch, account) and three tabs: **Tracker**, **Projects** and **Entries**. While a timer
runs, a small strip with the clock shows on the other tabs.


1. **Sign in** with email and password (`POST /api/auth/login`). The token is sent as
   `Authorization: Bearer <token>` on every other request, refreshed every 20 minutes
   (`POST /api/auth/refresh`) and on wake from sleep, and the session is restored on launch via
   `GET /api/auth/me`. An expired session returns you to the login screen.
2. **Workspaces** (`GET /api/workspaces`): pick one. The last one is reopened automatically; use the
   swap icon in the top bar to switch.
3. **Time tracker**: project (`GET /workspaces/:id/projects?memberId=`), task title, optional
   description, date, start time, tags (`GET /workspaces/:id/tags`) and a billable switch.
   - *Start time* defaults to **Now**. Set it to an earlier time and the timer counts from then.
   - **Start**, **Pause/Resume**, **End & save**. Ending posts the entry
     (`POST /workspaces/:id/time-entries`) and shows it in *Time entries*.
   - **Discard** throws a timer away after confirmation.
4. **Projects**: everything you're assigned to, with a one-click **Track** button.
5. **Time entries** (`GET /workspaces/:id/time-entries?userId=`): grouped by day with daily, today and
   weekly totals.

## How the timer behaves

- Elapsed time is computed from timestamps, not by counting ticks, so it stays correct through UI
  stalls and restarts. Because it is wall-clock based, **time keeps counting while the Mac sleeps**;
  pause the timer if you step away.
- The whole tracker state (form + timer) is saved to disk on every change. Quit the app mid-timer and
  it picks up where it left off.
- On End, the entry is written to a local queue *before* the upload. If the network or server fails,
  nothing is lost: a banner offers **Retry** (also retried automatically on next launch) or **Discard**.
- Durations are rounded to the nearest minute. The API requires at least 1 minute, so a timer under
  30 seconds is dropped with a notice. A single entry is capped at 24 hours by the API, so longer runs
  are split into consecutive days.

## Layout

```
lib/
  core/       API client, local storage, formatting helpers
  models/     User, Workspace, Project, Tag, TimeEntry
  state/      AuthController, WorkspacesController, WorkspaceSession, TrackerController
  features/   auth, workspaces, shell (navigation), tracker, projects, entries
macos/        Runner config (sandbox network entitlement, window size, app icon set)
test/         unit tests, API client tests, end-to-end widget flow against a fake backend
tool/         generate_icons_test.dart: renders the macOS app icon from the logo painter
branding/     timmy_icon_1024.png master
```

## Logo

The mark (a lowercase "t" on a pastel disc, on a dark tile, matching Gitty and Maggy) is drawn in code by
`TimmyLogoPainter` in `lib/widgets/timmy_logo.dart`. The app uses it on the login screen, and the macOS icon
set is rendered from the same painter, so tweak it there and regenerate:

```bash
flutter test tool/generate_icons_test.dart
```

## Notes

- The sandbox needs `com.apple.security.network.client` (already set in both entitlements files);
  without it every request fails silently on macOS.
- The auth token is stored in app preferences (like the web app's `localStorage`), not the Keychain.
- On Flutter 3.44.1 with the current Xcode, `flutter build macos --release` fails in the Flutter tool's
  framework-architecture check even for a brand-new blank app (`lipo` lists `x86_64 arm64`, the tool
  expects `arm64 x86_64`). Debug builds (`flutter run`) are unaffected; try `flutter upgrade` for release.
