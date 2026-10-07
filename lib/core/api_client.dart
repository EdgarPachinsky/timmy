import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/models.dart';

class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode, this.isNetwork = false});

  final String message;
  final int? statusCode;

  /// True when the server could not be reached at all.
  final bool isNetwork;

  bool get isUnauthorized => statusCode == 401;

  @override
  String toString() => message;
}

class LoginResult {
  const LoginResult({required this.user, required this.token});
  final User user;
  final String token;
}

/// Thin client for the Time-Wise REST API.
///
/// Authenticated calls send `Authorization: Bearer <token>`. A 401 on an
/// authenticated call invokes [onUnauthorized] so the app can drop the session.
class ApiClient {
  ApiClient({String? baseUrl, http.Client? httpClient})
      : baseUrl = baseUrl ?? _defaultBaseUrl,
        _http = httpClient ?? http.Client();

  static const _defaultBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://time-wise.codebnb.me',
  );
  static const _timeout = Duration(seconds: 20);

  final String baseUrl;
  final http.Client _http;

  String? token;
  VoidCallback? onUnauthorized;

  Future<LoginResult> login(String email, String password) async {
    final json = await _request(
      'POST',
      '/api/auth/login',
      body: {'email': email, 'password': password},
      authenticated: false,
    ) as Map<String, dynamic>;
    return LoginResult(
      user: User.fromJson(json['user'] as Map<String, dynamic>),
      token: json['token'] as String,
    );
  }

  Future<User> me() async => User.fromJson(
      await _request('GET', '/api/auth/me') as Map<String, dynamic>);

  /// Exchanges the current token for a fresh one.
  Future<String> refreshToken() async {
    final json =
        await _request('POST', '/api/auth/refresh') as Map<String, dynamic>;
    return json['token'] as String;
  }

  Future<void> logout() => _request('POST', '/api/auth/logout');

  Future<List<Workspace>> workspaces() async => _list(
        await _request('GET', '/api/workspaces'),
        Workspace.fromJson,
      );

  Future<List<Project>> projects(int workspaceId, {required int memberId}) async =>
      _list(
        await _request(
          'GET',
          '/api/workspaces/$workspaceId/projects',
          query: {'memberId': '$memberId'},
        ),
        Project.fromJson,
      );

  Future<List<Tag>> tags(int workspaceId) async => _list(
        await _request('GET', '/api/workspaces/$workspaceId/tags'),
        Tag.fromJson,
      );

  Future<List<TimeEntry>> timeEntries(int workspaceId, {required int userId}) async =>
      _list(
        await _request(
          'GET',
          '/api/workspaces/$workspaceId/time-entries',
          query: {'userId': '$userId'},
        ),
        TimeEntry.fromJson,
      );

  Future<TimeEntry> createTimeEntry(
    int workspaceId,
    Map<String, dynamic> payload,
  ) async =>
      TimeEntry.fromJson(await _request(
        'POST',
        '/api/workspaces/$workspaceId/time-entries',
        body: payload,
      ) as Map<String, dynamic>);

  /// Updates an entry with `PATCH`; [payload] has the same shape as for
  /// [createTimeEntry]. Returns the entry as Time-Wise now has it.
  Future<TimeEntry> updateTimeEntry(
    int workspaceId,
    int entryId,
    Map<String, dynamic> payload,
  ) async =>
      TimeEntry.fromJson(await _request(
        'PATCH',
        '/api/workspaces/$workspaceId/time-entries/$entryId',
        body: payload,
      ) as Map<String, dynamic>);

  Future<void> deleteTimeEntry(int workspaceId, int entryId) =>
      _request('DELETE', '/api/workspaces/$workspaceId/time-entries/$entryId');

  List<T> _list<T>(dynamic json, T Function(Map<String, dynamic>) parse) => [
        for (final item in json as List<dynamic>) parse(item as Map<String, dynamic>),
      ];

  Future<dynamic> _request(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    bool authenticated = true,
  }) async {
    final uri = Uri.parse(baseUrl).replace(path: path, queryParameters: query);
    final request = http.Request(method, uri)
      ..headers['Accept'] = 'application/json';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    if (authenticated && token != null) {
      request.headers['Authorization'] = 'Bearer $token';
    }

    final http.Response response;
    try {
      response = await http.Response.fromStream(
        await _http.send(request).timeout(_timeout),
      );
    } on TimeoutException {
      throw const ApiException('The server took too long to respond.',
          isNetwork: true);
    } on IOException {
      throw const ApiException(
          "Can't reach the server. Check your internet connection.",
          isNetwork: true);
    } on http.ClientException {
      throw const ApiException(
          "Can't reach the server. Check your internet connection.",
          isNetwork: true);
    }

    dynamic decoded;
    if (response.bodyBytes.isNotEmpty) {
      try {
        decoded = jsonDecode(utf8.decode(response.bodyBytes));
      } on FormatException {
        decoded = null;
      }
    }

    if (response.statusCode >= 200 && response.statusCode < 300) return decoded;

    if (response.statusCode == 401 && authenticated) onUnauthorized?.call();

    final serverMessage = decoded is Map
        ? (decoded['error'] ?? decoded['message'])?.toString()
        : null;
    throw ApiException(
      serverMessage ?? 'Request failed (${response.statusCode}).',
      statusCode: response.statusCode,
    );
  }
}
