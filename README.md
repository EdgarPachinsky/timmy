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
   - **Discard** throws a timer away after confirmation. The End menu offers the same as
     **Stop without saving** (in red, below the two save options).
   - **Add time** (after the timer status, or + in the *Entries* header) adds time by hand, without the timer: the entry
     editor with a *Time-Wise / This Mac* switch for where it goes.
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

The **Plan** tab turns everything you have into today's plan (`lib/core/planner.dart`):

- **Jira issues** (when connected), **Trello cards on you** (when connected: card members include you;
  lists named *Done* are skipped, *Doing* counts as in progress, labels like *urgent* / *high* set
  priority), and **recent work** from your own entries of the last 14 days that isn't one of those
  tasks: one task per title, with your latest note as its description (meetings, standups and calls
  are left out). With nothing connected the plan comes from recent work alone.
- Tasks are ranked by priority, being in progress, due date, how long they've been yours and whether
  you've worked on them today; recent work by how recently you worked on it. Tasks in review / test /
  blocked columns are listed apart.
- Each gets a time: what's left of its Jira estimate, else a typical amount for its type (bug 1h 30m,
  task 2h, story 3h); recent work gets about what a day of it took. Between 30m and 4h, filling
  whatever is left of an 8h day after the time already tracked; the rest goes to *Later*.
- Heads-ups: overtime today, overdue tasks, 3+ tasks in progress, tasks yours for 10+ days with no
  time logged, time over the estimate, and entries only on this Mac.
- Time on a task is found from entries naming it (the Jira key, or the Trello card's name);
  **Start** fills the tracker with the task and the project it was last tracked on, and starts the
  timer. The clock-plus button next to it **logs the planned time** instead: *Add time* opens with
  the task, its planned hours, today and that project, to save to Time-Wise or keep on this Mac.
  It greys out once the task has time today. **Log all to Time-Wise** (under today's plan) posts
  every planned task without time yet in one go, each on its last project (else the tracker's),
  with Undo.
- **Ask Claude to plan** sends all of it (descriptions and your notes included), so Claude can skip
  work your notes say is finished and merge a ticket with the matching recent work.
- **Write standup** builds Yesterday / Today / Blockers from your entries and notes, the current status
  of the Jira issues and Trello cards they were on ("· now In Review"), the plan, and blocked tasks.
  With Claude connected it's written as short first-person sentences to read out on the call.

## Claude

**Settings → Connectors → Claude** uses the [Claude Code](https://code.claude.com/docs/en/overview) CLI
on this Mac, with whoever is logged in to it, so no API key is needed. Timmy finds `claude` through your
login shell (or a path you set), shows the account from `claude auth status`, and can **log in** (opens
Terminal with `claude auth login`), **switch account** or **log out** (which signs Claude Code out on the
whole Mac); **Disconnect from Timmy** only stops Timmy using it.

With Claude connected, the entry editor's *Description* shows a ✨ button while it's empty: Claude
writes a very short "what was done" (at most ~12 words) from the task's Jira issue or Trello card
description, earlier notes on the same task, the project and the time.

With Claude connected, the Plan tab can **Ask Claude to plan** (order and times with a reason per task,
via `--json-schema`) and the standup is written by Claude. Each request runs
`claude -p --output-format json --tools "" --disallowedTools "mcp__*" --permission-mode dontAsk
--no-session-persistence --safe-mode` in an empty temporary folder, with the data on stdin, so Claude can
only read it and answer. The connector page shows Timmy's own usage (requests, tokens and Claude Code's
cost estimate, today and this month); plan limits are shown by `/usage` in Claude Code.

Because macOS sandboxed apps can't start other programs, Timmy now runs **without the app sandbox**
(`com.apple.security.app-sandbox` is `false` in both entitlements files). On first launch it copies the
preferences it stored while sandboxed (session, timers, local entries, Jira) out of its old container.

## Menu bar

Timmy puts a **t** in a circle in the macOS menu bar. While a timer exists it becomes a pill with the
task and its time, e.g. `t CDEV-2345 22:34` (the Jira key when the title starts with one, else the
title shortened); filled while running, outlined while paused. Its menu shows:

- the running task with **Pause/Resume** and **End** (Save to Time-Wise / Keep on this Mac),
- what's tracked today,
- **Today's plan** from the Plan tab (with Jira connected); click a task to start it,
- the **last standup** (saved when Claude writes it or you copy it), with **Copy standup**,
- **Show Timmy** and **Quit Timmy**.

It's drawn natively in `macos/Runner/StatusItemController.swift`; Flutter sends it the state over the
`timmy/menu_bar` channel (`lib/core/status_bar.dart`) and the clock ticks on the native side.

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
- On Flutter 3.44.1, `flutter build macos --release` fails in `release_unpack_macos`: it expects the
  framework's architectures as `arm64 x86_64`, `lipo` lists `x86_64 arm64`. `Configs/Release.xcconfig`
  works around it with `ARCHS = arm64` (release builds are for Apple silicon only). Build and install with:
  `flutter build macos --release && cp -R build/macos/Build/Products/Release/Timmy.app /Applications/`
