import 'dart:async';

import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/format.dart';
import '../core/storage.dart';
import '../features/tracker/tracker_logic.dart';
import '../models/models.dart';

enum TimerPhase { idle, running, paused }

/// Result of ending the timer:
/// - [invalid]: a required field is missing; the timer keeps running.
/// - [tooShort]: under a minute, which Time-Wise won't accept; nothing was
///   uploaded and the timer is left as it was (it can still be kept locally).
/// - [saved]: uploaded.
/// - [failed]: upload failed; the entry stays queued for retry.
/// - [keptLocally]: stored on this Mac only, to upload later from Entries.
enum EndOutcome { invalid, tooShort, saved, failed, keptLocally }

/// A finished timer that isn't in Time-Wise yet: either queued for upload
/// (kept on disk until the server accepts it, so time is never lost to a
/// network error) or kept locally on purpose until the user uploads it.
class PendingEntry {
  const PendingEntry({
    required this.payload,
    required this.projectName,
    this.id = '',
    this.createdAt,
    this.seconds,
  });

  /// Exactly the JSON body for `POST /workspaces/:id/time-entries`.
  final Map<String, dynamic> payload;
  final String projectName;

  /// Identifies a locally kept entry for upload or deletion.
  final String id;

  /// When the timer was ended.
  final DateTime? createdAt;

  /// Exact tracked seconds, for entries kept locally under a minute (their
  /// payload says 0 minutes; they're uploaded as Time-Wise's 1-minute minimum).
  final int? seconds;

  /// True for a local entry shorter than a minute.
  bool get underAMinute => minutes == 0;

  int get minutes => (payload['hours'] as int) * 60 + (payload['minutes'] as int);
  int get projectId => payload['projectId'] as int;
  String get taskTitle => payload['taskTitle'] as String;
  String? get description => payload['description'] as String?;
  String get date => payload['date'] as String;
  bool get billable => payload['billable'] as bool? ?? false;
  List<int> get tagIds => [for (final id in payload['tagIds'] as List? ?? const []) id as int];

  /// Shaped like a server entry, for lists, totals and the planner.
  TimeEntry asTimeEntry({Project? project}) => TimeEntry(
        id: -1,
        projectId: projectId,
        project: project,
        taskTitle: taskTitle,
        description: description,
        totalMinutes: minutes,
        date: date,
        billable: billable,
        tags: const [],
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => {
        'payload': payload,
        'projectName': projectName,
        'id': id,
        'createdAt': createdAt?.toIso8601String(),
        'seconds': seconds,
      };

  factory PendingEntry.fromJson(Map<String, dynamic> json) => PendingEntry(
        payload: Map<String, dynamic>.from(json['payload'] as Map),
        projectName: json['projectName'] as String? ?? '',
        id: json['id'] as String? ?? '',
        createdAt: json['createdAt'] == null ? null : DateTime.tryParse(json['createdAt'] as String),
        seconds: json['seconds'] as int?,
      );
}

/// The time tracker: form fields, a wall-clock based stopwatch, and the queue
/// of finished entries being uploaded.
///
/// Elapsed time is derived from timestamps rather than counted tick by tick, so
/// it stays correct through UI stalls, app restarts and Mac sleep.
class TrackerController extends ChangeNotifier {
  TrackerController({
    required this._api,
    required this._storage,
    required this._user,
    required this._workspace,
    this.onEntrySaved,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _restore();
  }

  final ApiClient _api;
  final AppStorage _storage;
  final User _user;
  final Workspace _workspace;
  final DateTime Function() _now;

  /// Called after each entry is accepted by the server.
  final VoidCallback? onEntrySaved;

  // ---- Form -----------------------------------------------------------

  int? projectId;
  String projectName = '';
  String taskTitle = '';
  String description = '';
  Set<int> tagIds = {};
  bool billable = true;

  /// Day to book the time to. `null` means today.
  DateTime? date;

  /// Time the work began. `null` means "the moment Start is pressed".
  TimeOfDay? startTime;

  // ---- Timer ----------------------------------------------------------

  TimerPhase phase = TimerPhase.idle;
  DateTime? startedAt;
  Duration _accumulated = Duration.zero;
  DateTime? _resumedAt;

  // ---- Upload queue ---------------------------------------------------

  final List<PendingEntry> pending = [];
  bool saving = false;
  String? saveError;

  // ---- Kept on this Mac -----------------------------------------------

  /// Entries ended with "Keep on this Mac", newest last. Never uploaded
  /// automatically.
  final List<PendingEntry> local = [];

  /// Ids of [local] entries being uploaded right now.
  final Set<String> uploadingLocal = {};

  /// Why the last [end] call returned [EndOutcome.invalid].
  String? invalidReason;

  bool _disposed = false;

  bool get isActive => phase != TimerPhase.idle;
  bool get isRunning => phase == TimerPhase.running;

  Duration get elapsed {
    if (phase == TimerPhase.idle) return Duration.zero;
    var total = _accumulated;
    if (phase == TimerPhase.running && _resumedAt != null) {
      total += _now().difference(_resumedAt!);
    }
    return total.isNegative ? Duration.zero : total;
  }

  // ---- Form edits -----------------------------------------------------

  void setProject(Project project) {
    projectId = project.id;
    projectName = project.name;
    _changed();
  }

  void setTaskTitle(String value) {
    taskTitle = value;
    _changed();
  }

  void setDescription(String value) {
    description = value;
    _changed();
  }

  void toggleTag(int id) {
    tagIds = tagIds.contains(id) ? ({...tagIds}..remove(id)) : {...tagIds, id};
    _changed();
  }

  void setBillable(bool value) {
    billable = value;
    _changed();
  }

  void setDate(DateTime? value) {
    date = value == null ? null : dateOnly(value);
    _changed();
  }

  void setStartTime(TimeOfDay? value) {
    startTime = value;
    _changed();
  }

  /// Bumped when something other than the form (e.g. the planner) fills it,
  /// so the form's text fields know to refresh.
  int externalEdits = 0;

  /// Fills the form for a new task from elsewhere in the app. Only while no
  /// timer is running.
  void prefill({Project? project, required String title, String? description}) {
    if (isActive) return;
    if (project != null) {
      projectId = project.id;
      projectName = project.name;
    }
    taskTitle = title;
    if (description != null) this.description = description;
    externalEdits++;
    _changed();
  }

  // ---- Timer controls -------------------------------------------------

  /// Starts the timer. Returns a user-facing problem, or `null` on success.
  String? start() {
    if (isActive) return null;
    final now = _now();
    final day = date ?? dateOnly(now);

    final DateTime started;
    if (startTime != null) {
      started = DateTime(day.year, day.month, day.day, startTime!.hour, startTime!.minute);
    } else if (day == dateOnly(now)) {
      started = now;
    } else {
      return 'Pick a start time for a past date.';
    }
    if (started.isAfter(now)) return 'The start time is in the future.';

    phase = TimerPhase.running;
    startedAt = started;
    // A start time earlier today counts from that moment, not from "now".
    _accumulated = now.difference(started);
    _resumedAt = now;
    _changed();
    return null;
  }

  void pause() {
    if (phase != TimerPhase.running) return;
    _accumulated = elapsed;
    _resumedAt = null;
    phase = TimerPhase.paused;
    _changed();
  }

  void resume() {
    if (phase != TimerPhase.paused) return;
    _resumedAt = _now();
    phase = TimerPhase.running;
    _changed();
  }

  /// Throws away the current timer without saving anything.
  void discard() {
    _resetTimer();
    date = null;
    startTime = null;
    _changed();
  }

  /// Stops the timer and saves the tracked time.
  ///
  /// With [upload] the entry is queued on disk first, then sent; if the upload
  /// fails it stays queued and [saveError] explains why. Without it the entry
  /// is kept in [local] until [uploadLocal] is called.
  Future<EndOutcome> end({bool upload = true}) async {
    if (!isActive) return EndOutcome.saved;
    final minutes = roundToMinutes(elapsed);
    final id = projectId;

    // Fields can be edited while the timer runs; make sure the entry will be
    // accepted before stopping, so the time is never stranded.
    final problem = id == null
        ? 'Choose a project before ending the timer.'
        : taskTitle.trim().isEmpty
            ? 'Add a task title before ending the timer.'
            : null;
    if (problem != null) {
      invalidReason = problem;
      return EndOutcome.invalid;
    }

    // Time-Wise needs at least a minute; this Mac can keep anything.
    final seconds = elapsed.inSeconds;
    if (upload ? minutes < 1 : seconds < 1) return EndOutcome.tooShort;

    final endedAt = _now();
    final chunks = minutes < 1
        ? [EntryChunk(dateOnly(startedAt ?? endedAt), 0)]
        : splitIntoEntries(startedAt ?? endedAt, minutes);
    for (var i = 0; i < chunks.length; i++) {
      final chunk = chunks[i];
      (upload ? pending : local).add(PendingEntry(
        id: '${endedAt.microsecondsSinceEpoch}-$i',
        createdAt: endedAt,
        seconds: minutes < 1 ? seconds : null,
        projectName: projectName,
        payload: {
          'projectId': id!,
          'taskTitle': taskTitle.trim(),
          'description': description.trim().isEmpty ? null : description.trim(),
          'hours': chunk.hoursPart,
          'minutes': chunk.minutesPart,
          'date': dateKey(chunk.date),
          'billable': billable,
          'tagIds': tagIds.toList()..sort(),
        },
      ));
    }

    // Ready for the next entry; project and billable carry over.
    _resetTimer();
    taskTitle = '';
    description = '';
    tagIds = {};
    date = null;
    startTime = null;
    _changed();

    if (!upload) return EndOutcome.keptLocally;
    return await flushPending() ? EndOutcome.saved : EndOutcome.failed;
  }

  // ---- Kept on this Mac -----------------------------------------------

  /// Uploads one locally kept entry. Returns a user-facing error, or null
  /// once Time-Wise has it (it then leaves [local]).
  Future<String?> uploadLocal(String id) async {
    final entry = local.where((e) => e.id == id).firstOrNull;
    if (entry == null || uploadingLocal.contains(id)) return null;
    uploadingLocal.add(id);
    _notify();
    try {
      await _api.createTimeEntry(
        _workspace.id,
        // Under a minute goes up as Time-Wise's minimum of one minute.
        entry.underAMinute ? {...entry.payload, 'minutes': 1} : entry.payload,
      );
      local.removeWhere((e) => e.id == id);
      _persist();
      onEntrySaved?.call();
      return null;
    } on ApiException catch (e) {
      return e.message;
    } finally {
      uploadingLocal.remove(id);
      _notify();
    }
  }

  /// Uploads every locally kept entry, oldest first, stopping at the first
  /// failure. Returns its error, or null when all are uploaded.
  Future<String?> uploadAllLocal() async {
    for (final entry in [...local]) {
      final error = await uploadLocal(entry.id);
      if (error != null) return error;
    }
    return null;
  }

  /// Replaces a locally kept entry's fields with [payload] (same shape as an
  /// upload). An entry left at 0 minutes keeps its exact seconds.
  void updateLocal(String id, Map<String, dynamic> payload, {required String projectName}) {
    final i = local.indexWhere((e) => e.id == id);
    if (i < 0) return;
    final old = local[i];
    final stillShort = (payload['hours'] as int) == 0 && (payload['minutes'] as int) == 0;
    local[i] = PendingEntry(
      id: old.id,
      createdAt: old.createdAt,
      projectName: projectName,
      payload: payload,
      seconds: stillShort ? old.seconds : null,
    );
    _changed();
  }

  /// Keeps a new entry on this Mac from a ready [payload] ("Copy for today",
  /// "Add time"). [seconds] carries the exact time of an entry under a minute.
  void addLocal(Map<String, dynamic> payload, {required String projectName, int? seconds}) {
    final now = _now();
    local.add(PendingEntry(
      id: '${now.microsecondsSinceEpoch}-added',
      createdAt: now,
      projectName: projectName,
      payload: payload,
      seconds: seconds,
    ));
    _changed();
  }

  /// Deletes a locally kept entry without uploading it.
  void deleteLocal(String id) {
    local.removeWhere((e) => e.id == id);
    _changed();
  }

  /// Puts a just-deleted local entry back where it was, for Undo.
  void restoreLocal(PendingEntry entry, int index) {
    if (local.any((e) => e.id == entry.id)) return;
    local.insert(index.clamp(0, local.length), entry);
    _changed();
  }

  // ---- Upload queue ---------------------------------------------------

  /// Sends queued entries in order. Returns true once the queue is empty.
  Future<bool> flushPending() async {
    if (saving) return false;
    if (pending.isEmpty) return true;
    saving = true;
    saveError = null;
    _notify();
    try {
      while (pending.isNotEmpty) {
        await _api.createTimeEntry(_workspace.id, pending.first.payload);
        pending.removeAt(0);
        _persist();
        onEntrySaved?.call();
      }
      return true;
    } on ApiException catch (e) {
      saveError = e.message;
      return false;
    } finally {
      saving = false;
      _notify();
    }
  }

  /// Gives up on queued entries (e.g. the server keeps rejecting them).
  void discardPending() {
    pending.clear();
    saveError = null;
    _changed();
  }

  // ---- Persistence ----------------------------------------------------

  void _resetTimer() {
    phase = TimerPhase.idle;
    startedAt = null;
    _accumulated = Duration.zero;
    _resumedAt = null;
  }

  void _changed() {
    _persist();
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _persist() {
    unawaited(_storage.saveTrackerState(_user.id, _workspace.id, {
      'projectId': projectId,
      'projectName': projectName,
      'taskTitle': taskTitle,
      'description': description,
      'tagIds': tagIds.toList(),
      'billable': billable,
      'date': date == null ? null : dateKey(date!),
      'startTime': startTime == null ? null : '${startTime!.hour}:${startTime!.minute}',
      'phase': phase.name,
      'startedAt': startedAt?.toIso8601String(),
      'accumulatedMs': _accumulated.inMilliseconds,
      'resumedAt': _resumedAt?.toIso8601String(),
      'pending': [for (final p in pending) p.toJson()],
      'local': [for (final p in local) p.toJson()],
    }));
  }

  void _restore() {
    final s = _storage.trackerState(_user.id, _workspace.id);
    if (s == null) return;
    try {
      projectId = s['projectId'] as int?;
      projectName = s['projectName'] as String? ?? '';
      taskTitle = s['taskTitle'] as String? ?? '';
      description = s['description'] as String? ?? '';
      tagIds = {for (final id in (s['tagIds'] as List? ?? const [])) id as int};
      billable = s['billable'] as bool? ?? true;
      final savedDate = s['date'] as String?;
      date = savedDate == null ? null : parseDateKey(savedDate);
      final savedTime = s['startTime'] as String?;
      if (savedTime != null) {
        final parts = savedTime.split(':');
        startTime = TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
      }
      pending.addAll([
        for (final p in (s['pending'] as List? ?? const []))
          PendingEntry.fromJson(p as Map<String, dynamic>),
      ]);
      local.addAll([
        for (final p in (s['local'] as List? ?? const []))
          PendingEntry.fromJson(p as Map<String, dynamic>),
      ]);

      final savedPhase = TimerPhase.values.asNameMap()[s['phase']] ?? TimerPhase.idle;
      if (savedPhase != TimerPhase.idle) {
        phase = savedPhase;
        startedAt = DateTime.parse(s['startedAt'] as String);
        _accumulated = Duration(milliseconds: s['accumulatedMs'] as int);
        final resumed = s['resumedAt'] as String?;
        _resumedAt = resumed == null ? null : DateTime.parse(resumed);
        if (phase == TimerPhase.running && _resumedAt == null) phase = TimerPhase.paused;
      }
    } catch (_) {
      // Corrupt saved state: start fresh rather than crash on launch.
      _resetTimer();
      pending.clear();
      local.clear();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
