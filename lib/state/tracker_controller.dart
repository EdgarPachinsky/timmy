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
/// - [tooShort]: under a minute, nothing to save; the timer was discarded.
/// - [saved]: uploaded.
/// - [failed]: upload failed; the entry stays queued for retry.
enum EndOutcome { invalid, tooShort, saved, failed }

/// A finished timer waiting to be uploaded. Kept on disk until the server
/// accepts it, so tracked time is never lost to a network error.
class PendingEntry {
  const PendingEntry({required this.payload, required this.projectName});

  /// Exactly the JSON body for `POST /workspaces/:id/time-entries`.
  final Map<String, dynamic> payload;
  final String projectName;

  int get minutes => (payload['hours'] as int) * 60 + (payload['minutes'] as int);
  String get taskTitle => payload['taskTitle'] as String;
  String get date => payload['date'] as String;

  Map<String, dynamic> toJson() => {'payload': payload, 'projectName': projectName};

  factory PendingEntry.fromJson(Map<String, dynamic> json) => PendingEntry(
        payload: Map<String, dynamic>.from(json['payload'] as Map),
        projectName: json['projectName'] as String? ?? '',
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

  /// Stops the timer and uploads the tracked time.
  ///
  /// The entry is queued on disk first, then sent; if the upload fails it stays
  /// queued and [saveError] explains why.
  Future<EndOutcome> end() async {
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

    if (minutes < 1) {
      _resetTimer();
      date = null;
      startTime = null;
      _changed();
      return EndOutcome.tooShort;
    }

    for (final chunk in splitIntoEntries(startedAt ?? _now(), minutes)) {
      pending.add(PendingEntry(
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

    return await flushPending() ? EndOutcome.saved : EndOutcome.failed;
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
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
