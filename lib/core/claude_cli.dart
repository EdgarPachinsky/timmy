import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// What a finished command printed.
class CommandResult {
  const CommandResult(this.exitCode, this.stdout, this.stderr);

  final int exitCode;
  final String stdout;
  final String stderr;
}

/// Starts programs. Swapped for a fake in tests.
abstract class CommandRunner {
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    String? stdin,
    Map<String, String>? environment,
    String? workingDirectory,
    Duration timeout = const Duration(seconds: 30),
  });

  bool fileExists(String path);
}

class ProcessCommandRunner implements CommandRunner {
  const ProcessCommandRunner();

  @override
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    String? stdin,
    Map<String, String>? environment,
    String? workingDirectory,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      environment: environment,
      workingDirectory: workingDirectory,
    );
    final out = process.stdout.transform(utf8.decoder).join();
    final err = process.stderr.transform(utf8.decoder).join();
    if (stdin != null) process.stdin.write(stdin);
    await process.stdin.close();
    final int code;
    try {
      code = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill();
      rethrow;
    }
    return CommandResult(code, await out, await err);
  }

  @override
  bool fileExists(String path) => File(path).existsSync();
}

class ClaudeException implements Exception {
  const ClaudeException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Where the `claude` command is, and the PATH it needs (apps started from the
/// Dock don't get the terminal's PATH, and an npm install needs `node` on it).
class ClaudeLocation {
  const ClaudeLocation({required this.path, required this.pathEnv});

  final String path;
  final String pathEnv;
}

/// Who `claude auth status` says is logged in. Field names vary by version,
/// so they're read defensively.
class ClaudeAccount {
  const ClaudeAccount({
    required this.loggedIn,
    this.email,
    this.organization,
    this.plan,
    this.authMethod,
    this.raw = const {},
  });

  final bool loggedIn;
  final String? email;
  final String? organization;

  /// Subscription, e.g. "pro" or "max", when reported.
  final String? plan;

  /// `claude.ai`, `api_key`, `oauth_token`, … or `none`.
  final String? authMethod;
  final Map<String, dynamic> raw;

  factory ClaudeAccount.fromStatus(Map<String, dynamic> json, {required bool loggedIn}) {
    String? find(List<String> keys) {
      for (final key in keys) {
        Object? value = json;
        for (final part in key.split('.')) {
          value = value is Map ? value[part] : null;
        }
        if (value is String && value.trim().isNotEmpty) return value.trim();
      }
      return null;
    }

    final method = find(['authMethod', 'auth_method']);
    return ClaudeAccount(
      loggedIn: loggedIn && method != 'none',
      email: find(['email', 'emailAddress', 'account.email', 'account.emailAddress', 'user.email']),
      organization: find([
        'orgName',
        'organizationName',
        'organization',
        'organization.name',
        'account.organizationName',
      ]),
      plan: find(['subscriptionType', 'subscription', 'plan', 'account.subscriptionType']),
      authMethod: method,
      raw: json,
    );
  }
}

/// One answer from `claude -p`, with what it cost.
class ClaudeAnswer {
  const ClaudeAnswer({
    required this.text,
    this.structured,
    this.costUsd = 0,
    this.inputTokens = 0,
    this.outputTokens = 0,
  });

  final String text;

  /// The JSON object matching the requested schema, if one was given.
  final Map<String, dynamic>? structured;

  /// Claude Code's own estimate (API-equivalent; a subscription isn't billed
  /// per request).
  final double costUsd;
  final int inputTokens;
  final int outputTokens;
}

/// Talks to the Claude Code CLI installed on this Mac.
class ClaudeCli {
  ClaudeCli({this.runner = const ProcessCommandRunner()});

  final CommandRunner runner;

  /// Set once a Claude Code too old for `--safe-mode` rejects it.
  bool _safeModeUnsupported = false;

  static const _shells = ['/bin/zsh', '/bin/bash'];

  /// Finds `claude`: [preferred] first, then the user's login shell (which
  /// also gives the PATH it needs), then the usual install places.
  Future<ClaudeLocation?> locate({String? preferred}) async {
    String? shellPath;
    String? shellFound;
    for (final shell in _shells) {
      if (!runner.fileExists(shell)) continue;
      try {
        final result = await runner.run(
          shell,
          ['-ilc', r'printf "__TIMMY__%s__TIMMY__%s__TIMMY__" "$(command -v claude)" "$PATH"'],
          timeout: const Duration(seconds: 15),
        );
        final parts = result.stdout.split('__TIMMY__');
        if (parts.length >= 4) {
          shellFound = parts[1].trim().isEmpty ? null : parts[1].trim();
          shellPath = parts[2].trim();
          break;
        }
      } on Exception {
        // Try the next shell.
      }
    }

    final home = Platform.environment['HOME'] ?? '';
    final candidates = [
      if (preferred != null && preferred.trim().isNotEmpty) preferred.trim(),
      if (shellFound != null) shellFound,
      '$home/.local/bin/claude',
      '$home/.claude/local/claude',
      '/opt/homebrew/bin/claude',
      '/usr/local/bin/claude',
    ];
    for (final path in candidates) {
      // `command -v` can report an alias or function rather than a file.
      if (path.startsWith('/') && runner.fileExists(path)) {
        final dir = path.substring(0, path.lastIndexOf('/'));
        final base = shellPath ?? Platform.environment['PATH'] ?? '/usr/bin:/bin';
        return ClaudeLocation(
          path: path,
          pathEnv: base.split(':').contains(dir) ? base : '$dir:$base',
        );
      }
    }
    return null;
  }

  Map<String, String> _env(ClaudeLocation at) => {...Platform.environment, 'PATH': at.pathEnv};

  Future<String?> version(ClaudeLocation at) async {
    final result = await runner.run(at.path, ['--version'], environment: _env(at));
    final text = result.stdout.trim();
    return result.exitCode == 0 && text.isNotEmpty ? text.split('\n').first : null;
  }

  /// `claude auth status`: exits 0 when logged in, and prints JSON.
  Future<ClaudeAccount> status(ClaudeLocation at) async {
    final result = await runner.run(at.path, ['auth', 'status'], environment: _env(at));
    Map<String, dynamic> json = const {};
    try {
      final decoded = jsonDecode(result.stdout);
      if (decoded is Map<String, dynamic>) json = decoded;
    } on FormatException {
      // Older versions print text; the exit code still tells us.
    }
    return ClaudeAccount.fromStatus(json, loggedIn: result.exitCode == 0);
  }

  /// Logs Claude Code out on this Mac (terminal sessions included).
  Future<void> logout(ClaudeLocation at) async {
    final result = await runner.run(at.path, ['auth', 'logout'], environment: _env(at));
    if (result.exitCode != 0) {
      throw ClaudeException(_firstLine(result.stderr, result.stdout) ?? 'Logging out failed.');
    }
  }

  /// Opens Terminal running `claude auth login`, which signs in through the
  /// browser. Callers poll [status] to see when it's done.
  Future<void> openLoginInTerminal(ClaudeLocation at) async {
    final dir = await Directory.systemTemp.createTemp('timmy-claude-login');
    final script = File('${dir.path}/Log in to Claude.command');
    final quoted = "'${at.path.replaceAll("'", r"'\''")}'";
    await script.writeAsString('#!/bin/zsh -l\n'
        'clear\n'
        'echo "Timmy: logging in to Claude Code..."\n'
        'echo\n'
        '$quoted auth login\n'
        'echo\n'
        'echo "Done. You can close this window and go back to Timmy."\n');
    await runner.run('/bin/chmod', ['+x', script.path]);
    final opened = await runner.run('/usr/bin/open', [script.path]);
    if (opened.exitCode != 0) {
      throw ClaudeException(_firstLine(opened.stderr, opened.stdout) ?? "Couldn't open Terminal.");
    }
  }

  /// Asks Claude one question with `claude -p`: [input] goes in on stdin.
  /// No tools, MCP servers or personal customisations are loaded and nothing
  /// is saved as a session, so it can only read the input and answer. With a
  /// [schema] the answer is a JSON object in [ClaudeAnswer.structured].
  Future<ClaudeAnswer> ask(
    ClaudeLocation at, {
    required String instruction,
    required String input,
    Map<String, dynamic>? schema,
    String? model,
    Duration timeout = const Duration(minutes: 3),
  }) async {
    final dir = await Directory.systemTemp.createTemp('timmy-claude');
    try {
      List<String> args({required bool safeMode}) => [
            '-p',
            instruction,
            '--output-format',
            'json',
            '--tools',
            '',
            '--disallowedTools',
            'mcp__*',
            '--permission-mode',
            'dontAsk',
            '--no-session-persistence',
            if (safeMode) '--safe-mode',
            if (model != null && model.isNotEmpty) ...['--model', model],
            if (schema != null) ...['--json-schema', jsonEncode(schema)],
          ];

      Future<CommandResult> invoke(bool safeMode) => runner.run(
            at.path,
            args(safeMode: safeMode),
            stdin: input,
            environment: _env(at),
            workingDirectory: dir.path,
            timeout: timeout,
          );

      CommandResult result;
      try {
        result = await invoke(!_safeModeUnsupported);
        if (!_safeModeUnsupported && _rejectsFlag(result, '--safe-mode')) {
          _safeModeUnsupported = true;
          result = await invoke(false);
        }
      } on TimeoutException {
        throw const ClaudeException('Claude took too long to answer.');
      }
      return _parseAnswer(result);
    } finally {
      unawaited(dir.delete(recursive: true).catchError((Object _) => dir));
    }
  }

  static bool _rejectsFlag(CommandResult result, String flag) {
    final text = '${result.stderr}\n${result.stdout}'.toLowerCase();
    return result.exitCode != 0 && text.contains(flag) && (text.contains('unknown') || text.contains('error'));
  }

  static ClaudeAnswer _parseAnswer(CommandResult result) {
    Map<String, dynamic>? json;
    try {
      final decoded = jsonDecode(result.stdout.trim());
      if (decoded is Map<String, dynamic>) json = decoded;
    } on FormatException {
      json = null;
    }
    if (json == null) {
      throw ClaudeException(
        _firstLine(result.stderr, result.stdout) ?? 'Claude Code exited with code ${result.exitCode}.',
      );
    }
    final text = (json['result'] as String? ?? '').trim();
    if (json['is_error'] == true || (result.exitCode != 0 && text.isNotEmpty)) {
      throw ClaudeException(text.isEmpty ? 'Claude Code reported an error.' : text);
    }
    final usage = json['usage'] as Map<String, dynamic>? ?? const {};
    int tokens(String key) => (usage[key] as num?)?.toInt() ?? 0;
    final structured = json['structured_output'];
    return ClaudeAnswer(
      text: text,
      structured: structured is Map<String, dynamic> ? structured : null,
      costUsd: (json['total_cost_usd'] as num?)?.toDouble() ?? 0,
      inputTokens: tokens('input_tokens') +
          tokens('cache_read_input_tokens') +
          tokens('cache_creation_input_tokens'),
      outputTokens: tokens('output_tokens'),
    );
  }

  static String? _firstLine(String a, String b) {
    for (final text in [a, b]) {
      final line = text.trim().split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
      if (line.trim().isNotEmpty) return line.trim();
    }
    return null;
  }
}
