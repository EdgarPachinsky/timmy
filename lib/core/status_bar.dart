import 'package:flutter/services.dart';

/// Timmy's icon in the macOS menu bar (drawn natively, see
/// `macos/Runner/StatusItemController.swift`).
///
/// [update] sends what the icon and its menu show; the running clock ticks on
/// the native side from `elapsedMs`, so this only needs calling on changes.
/// Menu clicks come back through [onAction]: `pause`, `resume`, `end_upload`,
/// `end_local` and `plan:<index>`.
class StatusBarItem {
  StatusBarItem({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('timmy/menu_bar') {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'action' && call.arguments is String) _onAction?.call(call.arguments as String);
    });
  }

  final MethodChannel _channel;
  Object? _owner;
  void Function(String action)? _onAction;

  /// Makes [owner] the one that feeds the item and handles its clicks. A
  /// workspace opened after another claims it before the old one is gone.
  void claim(Object owner, void Function(String action) onAction) {
    _owner = owner;
    _onAction = onAction;
  }

  /// Back to the bare icon, unless someone else has claimed it since.
  void release(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _onAction = null;
    update(const {});
  }

  Future<void> update(Map<String, Object?> state) => _invoke('update', state);

  /// Brings the Timmy window to the front.
  Future<void> showWindow() => _invoke('show');

  Future<void> _invoke(String method, [Object? arguments]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // Not on macOS, or in tests.
    } on PlatformException {
      // The menu bar is a convenience; never let it break the app.
    }
  }
}

final _issueKey = RegExp(r'^[A-Z][A-Z0-9]+-\d+');

/// What the menu bar pill shows for a task: its Jira key ("CDEV-2345 Fix
/// login" → "CDEV-2345"), else the title cut to [max] characters.
String statusBarLabel(String title, {int max = 18}) {
  final t = title.trim();
  final key = _issueKey.firstMatch(t);
  if (key != null) return key.group(0)!;
  return ellipsize(t, max);
}

/// [text] on one line, cut to [max] characters with "…".
String ellipsize(String text, int max) {
  final line = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return line.length <= max ? line : '${line.substring(0, max - 1).trimRight()}…';
}
