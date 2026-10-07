import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timmy/core/claude_cli.dart';
import 'package:timmy/core/storage.dart';
import 'package:timmy/state/claude_controller.dart';

/// Pretends to be the shell and the `claude` CLI.
class FakeRunner implements CommandRunner {
  final calls = <(String, List<String>, String?)>[];
  bool loggedIn = true;
  bool supportsSafeMode = true;
  Map<String, dynamic> answer = {
    'type': 'result',
    'is_error': false,
    'result': 'Hello',
    'total_cost_usd': 0.0123,
    'usage': {'input_tokens': 100, 'cache_read_input_tokens': 50, 'output_tokens': 20},
  };

  static const claudePath = '/Users/me/.local/bin/claude';

  @override
  bool fileExists(String path) => path == '/bin/zsh' || path == claudePath;

  @override
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    String? stdin,
    Map<String, String>? environment,
    String? workingDirectory,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls.add((executable, arguments, stdin));
    if (executable == '/bin/zsh') {
      return const CommandResult(0, 'noise from .zshrc __TIMMY__${claudePath}__TIMMY__/opt/homebrew/bin:/usr/bin__TIMMY__', '');
    }
    if (executable == claudePath) {
      if (arguments.first == '--version') return const CommandResult(0, '2.1.290 (Claude Code)\n', '');
      if (arguments.take(2).join(' ') == 'auth status') {
        return loggedIn
            ? CommandResult(0, jsonEncode({
                'loggedIn': true,
                'authMethod': 'claude.ai',
                'email': 'edgar@example.com',
                'orgName': 'STDev',
                'subscriptionType': 'max',
              }), '')
            : CommandResult(1, jsonEncode({'loggedIn': false, 'authMethod': 'none'}), '');
      }
      if (arguments.take(2).join(' ') == 'auth logout') {
        loggedIn = false;
        return const CommandResult(0, 'Logged out', '');
      }
      if (arguments.first == '-p') {
        if (!supportsSafeMode && arguments.contains('--safe-mode')) {
          return const CommandResult(1, '', "error: unknown option '--safe-mode'");
        }
        return CommandResult(0, jsonEncode(answer), '');
      }
    }
    return const CommandResult(0, '', '');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ClaudeCli', () {
    test('locate reads the login shell for the path and PATH', () async {
      final cli = ClaudeCli(runner: FakeRunner());
      final at = await cli.locate();
      expect(at!.path, FakeRunner.claudePath);
      expect(at.pathEnv, startsWith('/Users/me/.local/bin:'));
      expect(at.pathEnv, contains('/opt/homebrew/bin'));
    });

    test('status reads who is logged in', () async {
      final runner = FakeRunner();
      final cli = ClaudeCli(runner: runner);
      final at = (await cli.locate())!;
      final account = await cli.status(at);
      expect(account.loggedIn, isTrue);
      expect(account.email, 'edgar@example.com');
      expect(account.organization, 'STDev');
      expect(account.plan, 'max');
      expect(account.authMethod, 'claude.ai');

      runner.loggedIn = false;
      expect((await cli.status(at)).loggedIn, isFalse);
    });

    test('ask runs claude -p without tools and parses the answer and usage', () async {
      final runner = FakeRunner()
        ..answer = {
          'is_error': false,
          'result': '',
          'structured_output': {'plan': <Object>[], 'note': 'Focus.'},
          'total_cost_usd': 0.02,
          'usage': {'input_tokens': 10, 'output_tokens': 5},
        };
      final cli = ClaudeCli(runner: runner);
      final at = (await cli.locate())!;
      final answer = await cli.ask(
        at,
        instruction: 'Plan',
        input: '{"tasks":[]}',
        schema: {'type': 'object'},
        model: 'haiku',
      );
      final (exe, args, stdin) = runner.calls.last;
      expect(exe, FakeRunner.claudePath);
      expect(args.first, '-p');
      expect(args, containsAllInOrder(['--output-format', 'json']));
      expect(args, containsAllInOrder(['--tools', '']));
      expect(args, containsAllInOrder(['--model', 'haiku']));
      expect(args, containsAllInOrder(['--json-schema', '{"type":"object"}']));
      expect(args, contains('--no-session-persistence'));
      expect(stdin, '{"tasks":[]}');
      expect(answer.structured!['note'], 'Focus.');
      expect(answer.costUsd, 0.02);
      expect(answer.inputTokens, 10);
    });

    test('falls back when this Claude Code is too old for --safe-mode', () async {
      final runner = FakeRunner()..supportsSafeMode = false;
      final cli = ClaudeCli(runner: runner);
      final at = (await cli.locate())!;
      expect((await cli.ask(at, instruction: 'Hi', input: '')).text, 'Hello');
      await cli.ask(at, instruction: 'Again', input: '');
      // Second call goes straight to the version without the flag.
      expect(runner.calls.last.$2, isNot(contains('--safe-mode')));
    });

    test('errors Claude reports become exceptions', () async {
      final runner = FakeRunner()..answer = {'is_error': true, 'result': 'Not logged in · Please run /login'};
      final cli = ClaudeCli(runner: runner);
      final at = (await cli.locate())!;
      await expectLater(
        cli.ask(at, instruction: 'Hi', input: ''),
        throwsA(isA<ClaudeException>().having((e) => e.message, 'message', contains('/login'))),
      );
    });
  });

  group('ClaudeController', () {
    late AppStorage storage;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      storage = AppStorage(await SharedPreferences.getInstance());
    });

    test('connect finds Claude Code and shows the account; it is remembered', () async {
      final claude = ClaudeController(cli: ClaudeCli(runner: FakeRunner()), storage: storage);
      expect(claude.isConnected, isFalse);
      await claude.connect();
      expect(claude.status, ClaudeStatus.loggedIn);
      expect(claude.isConnected, isTrue);
      expect(claude.account!.email, 'edgar@example.com');
      expect(claude.version, contains('2.1.290'));
      expect(ClaudeController(cli: ClaudeCli(runner: FakeRunner()), storage: storage).enabled, isTrue);
    });

    test('disconnect stops Timmy using it but keeps Claude Code logged in', () async {
      final runner = FakeRunner();
      final claude = ClaudeController(cli: ClaudeCli(runner: runner), storage: storage);
      await claude.connect();
      await claude.disconnect();
      expect(claude.isConnected, isFalse);
      expect(runner.loggedIn, isTrue);
      expect(runner.calls.where((c) => c.$2.contains('logout')), isEmpty);
    });

    test('logout signs Claude Code out', () async {
      final runner = FakeRunner();
      final claude = ClaudeController(cli: ClaudeCli(runner: runner), storage: storage);
      await claude.connect();
      await claude.logout();
      expect(claude.status, ClaudeStatus.loggedOut);
      expect(claude.isConnected, isFalse);
    });

    test('ask records usage for today and this month', () async {
      final now = DateTime(2026, 10, 8, 9);
      final claude = ClaudeController(cli: ClaudeCli(runner: FakeRunner()), storage: storage, now: () => now);
      await claude.connect();
      await claude.ask(kind: 'standup', instruction: 'Write', input: '{}');
      await claude.ask(kind: 'plan', instruction: 'Plan', input: '{}');
      expect(claude.usageToday.requests, 2);
      expect(claude.usageToday.inputTokens, 300); // 100 + 50 cache, twice
      expect(claude.usageToday.outputTokens, 40);
      expect(claude.usageThisMonth.costUsd, closeTo(0.0246, 1e-9));
      // Kept across restarts.
      final again = ClaudeController(cli: ClaudeCli(runner: FakeRunner()), storage: storage, now: () => now);
      expect(again.usageThisMonth.requests, 2);
    });

    test('asking while not connected explains how to connect', () async {
      final claude = ClaudeController(cli: ClaudeCli(runner: FakeRunner()), storage: storage);
      await expectLater(
        claude.ask(kind: 'plan', instruction: 'x', input: ''),
        throwsA(isA<ClaudeException>().having((e) => e.message, 'message', contains('Connectors'))),
      );
    });
  });
}
