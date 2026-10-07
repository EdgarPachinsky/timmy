import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/claude_cli.dart';
import '../core/storage.dart';

enum ClaudeStatus {
  /// Not checked yet.
  unknown,
  checking,

  /// No `claude` command found.
  notInstalled,
  loggedOut,
  loggedIn,

  /// The check itself failed; see [ClaudeController.error].
  error,
}

/// One request Timmy made to Claude, for the usage panel.
class ClaudeUsageRecord {
  const ClaudeUsageRecord({
    required this.at,
    required this.kind,
    required this.inputTokens,
    required this.outputTokens,
    required this.costUsd,
  });

  final DateTime at;

  /// What it was for, e.g. "plan" or "standup".
  final String kind;
  final int inputTokens;
  final int outputTokens;
  final double costUsd;

  Map<String, dynamic> toJson() => {
        'at': at.toIso8601String(),
        'kind': kind,
        'in': inputTokens,
        'out': outputTokens,
        'cost': costUsd,
      };

  factory ClaudeUsageRecord.fromJson(Map<String, dynamic> json) => ClaudeUsageRecord(
        at: DateTime.parse(json['at'] as String),
        kind: json['kind'] as String? ?? '',
        inputTokens: (json['in'] as num?)?.toInt() ?? 0,
        outputTokens: (json['out'] as num?)?.toInt() ?? 0,
        costUsd: (json['cost'] as num?)?.toDouble() ?? 0,
      );
}

class ClaudeUsageSummary {
  const ClaudeUsageSummary(this.requests, this.inputTokens, this.outputTokens, this.costUsd);

  final int requests;
  final int inputTokens;
  final int outputTokens;
  final double costUsd;
}

/// The Claude connector: uses the Claude Code CLI on this Mac (and whoever is
/// logged in to it) for the planner and standups.
///
/// "Connected" means the user turned it on here *and* Claude Code is logged
/// in. Disconnecting only stops Timmy using it; logging out signs Claude Code
/// out on the whole Mac.
class ClaudeController extends ChangeNotifier {
  ClaudeController({required ClaudeCli cli, required AppStorage storage, DateTime Function()? now})
      : _cli = cli,
        _storage = storage,
        _now = now ?? DateTime.now {
    _load();
    if (_enabled) unawaited(check());
  }

  final ClaudeCli _cli;
  final AppStorage _storage;
  final DateTime Function() _now;

  /// Usage older than this is dropped.
  static const _keepUsage = Duration(days: 62);

  bool _enabled = false;
  String _preferredPath = '';
  String _model = '';
  final List<ClaudeUsageRecord> _usage = [];

  ClaudeStatus _status = ClaudeStatus.unknown;
  ClaudeLocation? _location;
  String? _version;
  ClaudeAccount? _account;
  String? _error;
  bool _waitingForLogin = false;
  bool _busy = false;
  Timer? _loginPoll;
  bool _disposed = false;

  bool get enabled => _enabled;
  bool get isConnected => _enabled && _status == ClaudeStatus.loggedIn;
  ClaudeStatus get status => _status;
  ClaudeAccount? get account => _account;
  String? get version => _version;
  String? get error => _error;
  String? get path => _location?.path;

  /// Path the user typed, tried before searching.
  String get preferredPath => _preferredPath;

  /// Model alias for requests (`haiku`, `sonnet`, `opus`), or '' for Claude
  /// Code's default.
  String get model => _model;

  /// Terminal is open for `claude auth login`; Timmy is waiting for it.
  bool get waitingForLogin => _waitingForLogin;

  /// A login, logout or check is running.
  bool get busy => _busy || _status == ClaudeStatus.checking;

  List<ClaudeUsageRecord> get usage => List.unmodifiable(_usage);

  void _load() {
    final saved = _storage.claudeSettings;
    if (saved == null) return;
    _enabled = saved['enabled'] as bool? ?? false;
    _preferredPath = saved['path'] as String? ?? '';
    _model = saved['model'] as String? ?? '';
    try {
      _usage.addAll([
        for (final r in saved['usage'] as List? ?? const [])
          ClaudeUsageRecord.fromJson(Map<String, dynamic>.from(r as Map)),
      ]);
    } catch (_) {
      _usage.clear();
    }
  }

  Future<void> _save() => _storage.saveClaudeSettings({
        'enabled': _enabled,
        'path': _preferredPath,
        'model': _model,
        'usage': [for (final r in _usage) r.toJson()],
      });

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Finds Claude Code and reads who is logged in.
  Future<void> check() async {
    if (_status == ClaudeStatus.checking) return;
    _status = ClaudeStatus.checking;
    _error = null;
    _notify();
    try {
      final location = _location ?? await _cli.locate(preferred: _preferredPath);
      if (location == null) {
        _location = null;
        _account = null;
        _status = ClaudeStatus.notInstalled;
        return;
      }
      _location = location;
      _version ??= await _cli.version(location);
      _account = await _cli.status(location);
      _status = _account!.loggedIn ? ClaudeStatus.loggedIn : ClaudeStatus.loggedOut;
    } on Exception catch (e) {
      _status = ClaudeStatus.error;
      _error = '$e';
    } finally {
      _notify();
    }
  }

  /// Turns the connector on (and checks Claude Code is ready).
  Future<void> connect() async {
    _enabled = true;
    await _save();
    _location = null; // Search afresh.
    await check();
  }

  /// Stops Timmy using Claude. Claude Code itself stays logged in.
  Future<void> disconnect() async {
    _enabled = false;
    _stopLoginPoll();
    _notify();
    await _save();
  }

  /// Uses [path] for `claude` (empty to search again), then re-checks.
  Future<void> setPreferredPath(String path) async {
    _preferredPath = path.trim();
    _location = null;
    _version = null;
    await _save();
    await check();
  }

  Future<void> setModel(String model) async {
    _model = model;
    _notify();
    await _save();
  }

  /// Opens Terminal with `claude auth login` and waits (up to 5 minutes) for
  /// the login to show up.
  Future<void> login() async {
    final location = _location;
    if (location == null) return;
    _busy = true;
    _error = null;
    _notify();
    try {
      await _cli.openLoginInTerminal(location);
      _waitingForLogin = true;
      final started = _now();
      _loginPoll?.cancel();
      _loginPoll = Timer.periodic(const Duration(seconds: 2), (_) async {
        if (_disposed) return;
        if (_now().difference(started) > const Duration(minutes: 5)) {
          _stopLoginPoll();
          return;
        }
        try {
          final account = await _cli.status(location);
          if (account.loggedIn) {
            _account = account;
            _status = ClaudeStatus.loggedIn;
            _enabled = true;
            await _save();
            _stopLoginPoll();
          }
        } on Exception {
          // Keep waiting.
        }
      });
    } on Exception catch (e) {
      _error = '$e';
    } finally {
      _busy = false;
      _notify();
    }
  }

  void _stopLoginPoll() {
    _loginPoll?.cancel();
    _loginPoll = null;
    _waitingForLogin = false;
    _notify();
  }

  /// Signs Claude Code out on this Mac.
  Future<void> logout() async {
    final location = _location;
    if (location == null) return;
    _busy = true;
    _error = null;
    _notify();
    try {
      await _cli.logout(location);
      _account = await _cli.status(location);
      _status = _account!.loggedIn ? ClaudeStatus.loggedIn : ClaudeStatus.loggedOut;
    } on Exception catch (e) {
      _error = '$e';
    } finally {
      _busy = false;
      _notify();
    }
  }

  /// Log out, then log in again (with another account).
  Future<void> switchAccount() async {
    await logout();
    if (_status == ClaudeStatus.loggedOut) await login();
  }

  /// Asks Claude and records the usage. Throws [ClaudeException].
  Future<ClaudeAnswer> ask({
    required String kind,
    required String instruction,
    required String input,
    Map<String, dynamic>? schema,
  }) async {
    final location = _location;
    if (!isConnected || location == null) {
      throw const ClaudeException('Connect Claude in Settings → Connectors first.');
    }
    final answer = await _cli.ask(
      location,
      instruction: instruction,
      input: input,
      schema: schema,
      model: _model,
    );
    final now = _now();
    _usage
      ..add(ClaudeUsageRecord(
        at: now,
        kind: kind,
        inputTokens: answer.inputTokens,
        outputTokens: answer.outputTokens,
        costUsd: answer.costUsd,
      ))
      ..removeWhere((r) => now.difference(r.at) > _keepUsage);
    _notify();
    unawaited(_save());
    return answer;
  }

  /// Usage since [from] (inclusive).
  ClaudeUsageSummary usageSince(DateTime from) {
    var requests = 0, input = 0, output = 0;
    var cost = 0.0;
    for (final r in _usage) {
      if (r.at.isBefore(from)) continue;
      requests++;
      input += r.inputTokens;
      output += r.outputTokens;
      cost += r.costUsd;
    }
    return ClaudeUsageSummary(requests, input, output, cost);
  }

  ClaudeUsageSummary get usageToday {
    final now = _now();
    return usageSince(DateTime(now.year, now.month, now.day));
  }

  ClaudeUsageSummary get usageThisMonth {
    final now = _now();
    return usageSince(DateTime(now.year, now.month));
  }

  @override
  void dispose() {
    _disposed = true;
    _loginPoll?.cancel();
    super.dispose();
  }
}
