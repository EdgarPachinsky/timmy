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

Timmy runs in a fixed, non-resizable compact window (344×770) with a top bar
(workspace, switch, projects, settings, account) and three tabs: **Tracker**, **Entries** and **Plan**. While a timer
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
   - **Start**, **Pause/Resume** and **End**. End asks where the time goes:
     **Save to Time-Wise** posts it now (`POST /workspaces/:id/time-entries`); **Keep on this Mac**
     stores it locally to review first. Local entries show in *Entries* with an upload (cloud) button,
     an *Upload all* banner and a delete button; entries already in Time-Wise show a cloud-check mark.
   - **Discard** throws a timer away after confirmation.
4. **Projects** (folder icon in the top bar): everything you're assigned to, with a one-click
   **Track** button that returns to the tracker with that project selected.
5. **Time entries** (`GET /workspaces/:id/time-entries?userId=`): grouped by day, with a project
   filter and today, week and month totals. **Overtime** is everything over 8h on a day (all entries
   that day added together, all projects): 9h → 1h, 12h → 4h. A card shows the month's overtime,
   with arrows to step back through earlier months, and each day over 8h gets a "+1h overtime" badge. Click an entry to edit its project, title, description,
   date, duration, tags or billable flag. Entries in Time-Wise are saved with
   `PATCH /workspaces/:id/time-entries/:entryId` (same body as creating one) and deleted with
   `DELETE /workspaces/:id/time-entries/:entryId`: from a row's trash icon or the editor, after a
   confirmation, with Undo in the snackbar (it re-creates the entry); entries kept on this Mac are
   edited and deleted locally.

## Jira

Open **Settings → Connectors → Jira** (gear in the top bar) and connect Jira Cloud with your site
(`your-team.atlassian.net`), Jira email and an [API token](https://id.atlassian.com/manage-profile/security/api-tokens).
The connection is checked with `GET /rest/api/3/myself` and saved per Timmy user.

Once connected, **Jira tasks** in the avatar menu opens a page to browse, filter (priority, type) and
search them. Click a task to read its full description; its links open in the browser
(`url_launcher`), and **Open in Jira** opens the issue itself. Click the status pill, or right-click a
task in any list, to move it to another column: Timmy lists the moves your workflow allows
(`GET /rest/api/3/issue/:key/transitions`) and applies the one you pick (`POST` to the same path). The search button in the tracker's *Task title* field lists the same tasks (key, status, title and
a short description) via `GET /rest/api/3/search/jql`. Search keeps tasks whose title or
description *contains* the text (Jira's own search only matches whole words, so Timmy merges its word
matches with your task list and filters them itself); typing a key like `CDEV-123` looks that issue up
directly. In Settings you can change which tasks are listed (JQL; by
default your open, assigned tasks) and whether picking fills the title with *key + title* or *key only*
(the Jira title then goes into an empty description). Like the Time-Wise token, the API token is stored
in app preferences, not the Keychain.

## Trello

**Settings → Connectors → Trello** connects with an API key and token: create a Power-Up at
[trello.com/power-ups/admin](https://trello.com/power-ups/admin) to get the key, then **Get token** opens
Trello's authorize page (`/1/authorize?expiration=never&scope=read,write&response_type=token`) for the
token to paste back. The connection is checked with `GET /1/members/me` and saved per Timmy user.

Cards come from `GET /1/members/me/cards` (assigned to you) or, if chosen, every open card on your open
boards (`GET /1/boards/:id/cards/open`, up to 15 boards); board and list names come from
`GET /1/members/me/boards?lists=open`. They're grouped by board and list, filterable by board, and
searched by "contains" over title, description, list and labels (or `#12` for a card number).

The search button in *Task title* (tracker and entry editor) picks from Jira or Trello: straight into
the picker when one is connected, or a small Jira / Trello menu when both are. A card fills the title
with its name, and optionally its link into the description. **Trello cards** in the avatar menu opens a
page to browse them; a card's details show its labels, due date and description (links clickable) and
**Open in Trello**.

## Plan

The **Plan** tab turns your Jira tasks into today's plan (`lib/core/planner.dart`):

- Tasks are ranked by priority, being in progress, due date (`duedate`), how long they've been yours
  and whether you've worked on them today. Tasks in review / test / blocked columns are listed apart.
- Each gets a time: what's left of its Jira estimate (`timetracking`), else a typical amount for its
  type (bug 1h 30m, task 2h, story 3h), between 30m and 4h. They fill whatever is left of an 8h day
  after the time already tracked (entries, local entries and a running timer); the rest goes to *Later*.
- Heads-ups: overtime today, overdue tasks, 3+ tasks in progress, tasks yours for 10+ days with no
  time logged, time over the estimate, and entries only on this Mac.
- Time logged on a task is found from entries whose title contains its key; **Start** fills the
  tracker with the task and the project it was last tracked on, and starts the timer.
- **Write standup** builds Yesterday / Today / Blockers from your entries and the plan.

## Claude

**Settings → Connectors → Claude** uses the [Claude Code](https://code.claude.com/docs/en/overview) CLI
on this Mac, with whoever is logged in to it, so no API key is needed. Timmy finds `claude` through your
login shell (or a path you set), shows the account from `claude auth status`, and can **log in** (opens
Terminal with `claude auth login`), **switch account** or **log out** (which signs Claude Code out on the
whole Mac); **Disconnect from Timmy** only stops Timmy using it.

With Claude connected, the Plan tab can **Ask Claude to plan** (order and times with a reason per task,
via `--json-schema`) and the standup is written by Claude. Each request runs
`claude -p --output-format json --tools "" --disallowedTools "mcp__*" --permission-mode dontAsk
--no-session-persistence --safe-mode` in an empty temporary folder, with the data on stdin, so Claude can
only read it and answer. The connector page shows Timmy's own usage (requests, tokens and Claude Code's
cost estimate, today and this month); plan limits are shown by `/usage` in Claude Code.

Because macOS sandboxed apps can't start other programs, Timmy now runs **without the app sandbox**
(`com.apple.security.app-sandbox` is `false` in both entitlements files). On first launch it copies the
preferences it stored while sandboxed (session, timers, local entries, Jira) out of its old container.

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

- The app is not sandboxed (see Claude above); `com.apple.security.network.client` stays set in both
  entitlements files in case the sandbox is ever turned back on.
- The auth token is stored in app preferences (like the web app's `localStorage`), not the Keychain.
- On Flutter 3.44.1 with the current Xcode, `flutter build macos --release` fails in the Flutter tool's
  framework-architecture check even for a brand-new blank app (`lipo` lists `x86_64 arm64`, the tool
  expects `arm64 x86_64`). Debug builds (`flutter run`) are unaffected; try `flutter upgrade` for release.
