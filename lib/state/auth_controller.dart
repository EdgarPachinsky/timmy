import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core/api_client.dart';
import '../core/storage.dart';
import '../models/models.dart';

enum AuthStatus { initializing, signedOut, signedIn }

class AuthController extends ChangeNotifier with WidgetsBindingObserver {
  AuthController(this._api, this._storage) {
    _api.onUnauthorized = _handleUnauthorized;
    WidgetsBinding.instance.addObserver(this);
  }

  /// Matches the web app, which refreshes its token every 20 minutes.
  static const _refreshInterval = Duration(minutes: 20);

  final ApiClient _api;
  final AppStorage _storage;

  AuthStatus _status = AuthStatus.initializing;
  User? _user;
  String? _notice;
  Timer? _refreshTimer;
  DateTime _lastRefresh = DateTime.now();

  AuthStatus get status => _status;
  User? get user => _user;

  /// One-off message for the login screen (e.g. "session expired").
  String? get notice => _notice;

  /// Restores a saved session, validating it against `/auth/me`.
  Future<void> restore() async {
    final token = _storage.token;
    if (token == null) {
      _status = AuthStatus.signedOut;
      notifyListeners();
      return;
    }
    _api.token = token;
    try {
      final user = await _api.me();
      await _storage.saveUser(user);
      _signIn(user);
    } on ApiException catch (e) {
      if (e.isUnauthorized) return; // _handleUnauthorized already ran.
      // Offline at launch: fall back to the cached profile so the timer and
      // any unsaved entries stay reachable; screens will show their own errors.
      final cached = _storage.user;
      if (cached != null) {
        _signIn(cached);
      } else {
        await _clearSession();
        _status = AuthStatus.signedOut;
        _notice = e.message;
        notifyListeners();
      }
    }
  }

  Future<void> login(String email, String password) async {
    final result = await _api.login(email.trim(), password);
    _api.token = result.token;
    await _storage.saveToken(result.token);
    await _storage.saveUser(result.user);
    _signIn(result.user);
  }

  Future<void> logout() async {
    // Best effort. The request captures the token synchronously, so it is safe
    // to clear the local session right away without waiting on the server.
    if (_api.token != null) unawaited(_api.logout().catchError((_) {}));
    await _clearSession();
    _status = AuthStatus.signedOut;
    _notice = null;
    notifyListeners();
  }

  void clearNotice() {
    if (_notice == null) return;
    _notice = null;
    notifyListeners();
  }

  void _signIn(User user) {
    _user = user;
    _status = AuthStatus.signedIn;
    _notice = null;
    _lastRefresh = DateTime.now();
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(_refreshInterval, (_) => _refresh());
    notifyListeners();
  }

  void _handleUnauthorized() {
    if (_status == AuthStatus.signedOut) return;
    _clearSession();
    _status = AuthStatus.signedOut;
    _notice = 'Your session expired. Please sign in again.';
    notifyListeners();
  }

  Future<void> _clearSession() async {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _api.token = null;
    _user = null;
    await _storage.clearSession();
  }

  Future<void> _refresh() async {
    if (_status != AuthStatus.signedIn) return;
    try {
      final token = await _api.refreshToken();
      _api.token = token;
      _lastRefresh = DateTime.now();
      await _storage.saveToken(token);
    } on ApiException {
      // Transient failures are retried on the next tick; a 401 signs us out.
    }
  }

  /// Timers pause while the Mac sleeps, so catch up when the app wakes.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _status == AuthStatus.signedIn &&
        DateTime.now().difference(_lastRefresh) >= _refreshInterval) {
      _refresh();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
    super.dispose();
  }
}
