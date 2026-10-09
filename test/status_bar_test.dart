import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timmy/core/status_bar.dart';
import 'package:timmy/core/storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('statusBarLabel', () {
    test('uses the Jira key when the title starts with one', () {
      expect(statusBarLabel('CDEV-2345 Fix the login page'), 'CDEV-2345');
      expect(statusBarLabel('  AB1-7'), 'AB1-7');
    });

    test('otherwise shortens the title', () {
      expect(statusBarLabel('Code review'), 'Code review');
      expect(statusBarLabel('A rather long task title here'), 'A rather long tas…');
      expect(statusBarLabel(''), '');
    });
  });

  test('ellipsize keeps one line', () {
    expect(ellipsize('two\nlines', 20), 'two lines');
    expect(ellipsize('abcdef', 4), 'abc…');
  });

  group('StatusBarItem', () {
    const channel = MethodChannel('timmy/menu_bar_test');
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async {
          calls.add(call);
          return null;
        },
      );
    });

    Future<void> click(String action) =>
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(MethodCall('action', action)),
          (_) {},
        );

    test('clicks go to the latest owner; a stale release changes nothing', () async {
      final item = StatusBarItem(channel: channel);
      final first = Object(), second = Object();
      final got = <String>[];
      item.claim(first, (a) => got.add('first:$a'));
      item.claim(second, (a) => got.add('second:$a'));
      item.release(first);
      await click('pause');
      expect(got, ['second:pause']);
      expect(calls, isEmpty);

      item.release(second);
      await Future<void>.delayed(Duration.zero);
      await click('resume');
      expect(got, ['second:pause']);
      expect(calls.single.method, 'update');
      expect(calls.single.arguments, isEmpty);
    });

    test('a missing native side is ignored', () async {
      final item = StatusBarItem(channel: const MethodChannel('timmy/nobody_home'));
      await item.update({'signedIn': true});
      await item.showWindow();
    });
  });

  test('the last standup is kept per user', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = AppStorage(await SharedPreferences.getInstance());
    expect(storage.lastStandup(1), isNull);
    final at = DateTime(2026, 10, 9, 10, 15);
    await storage.saveLastStandup(1, 'Yesterday: …', at);
    expect(storage.lastStandup(1)?.text, 'Yesterday: …');
    expect(storage.lastStandup(1)?.at, at);
    expect(storage.lastStandup(2), isNull);
  });
}
