import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/trello.dart';

class TrelloException implements Exception {
  const TrelloException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Minimal Trello REST client, authenticated with an API key and token.
class TrelloClient {
  TrelloClient({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  static const _timeout = Duration(seconds: 20);
  static const _cardFields =
      'name,desc,due,dueComplete,idList,idBoard,shortUrl,url,labels,dateLastActivity,idShort,idMembers';

  /// Boards' cards are fetched in parallel, at most this many boards.
  static const maxBoards = 15;

  final http.Client _http;

  /// The account the key and token belong to; used to verify a connection.
  Future<TrelloMember> me(TrelloCredentials credentials) async => TrelloMember.fromJson(
      await _get(credentials, '/1/members/me', {'fields': 'fullName,username,email'}) as Map<String, dynamic>);

  /// Open boards with their open lists.
  Future<List<TrelloBoard>> boards(TrelloCredentials credentials) async {
    final json = await _get(credentials, '/1/members/me/boards', {
      'filter': 'open',
      'fields': 'name,dateLastActivity',
      'lists': 'open',
      'list_fields': 'name,pos',
    }) as List<dynamic>;
    final boards = [for (final b in json) TrelloBoard.fromJson(b as Map<String, dynamic>)];
    // Older responses may leave lists out; fetch those boards' lists directly.
    return Future.wait([
      for (final board in boards)
        board.lists.isNotEmpty ? Future.value(board) : _withLists(credentials, board),
    ]);
  }

  Future<TrelloBoard> _withLists(TrelloCredentials credentials, TrelloBoard board) async {
    try {
      final lists = await _get(credentials, '/1/boards/${board.id}/lists', {'filter': 'open', 'fields': 'name'})
          as List<dynamic>;
      return TrelloBoard.fromJson({'id': board.id, 'name': board.name, 'lists': lists});
    } on TrelloException {
      return board;
    }
  }

  /// Open cards assigned to the user.
  Future<List<Map<String, dynamic>>> myCards(TrelloCredentials credentials) async =>
      [for (final c in await _get(credentials, '/1/members/me/cards', {'filter': 'open', 'fields': _cardFields}) as List<dynamic>) c as Map<String, dynamic>];

  /// Open cards on a board.
  Future<List<Map<String, dynamic>>> boardCards(TrelloCredentials credentials, String boardId) async =>
      [for (final c in await _get(credentials, '/1/boards/$boardId/cards/open', {'fields': _cardFields}) as List<dynamic>) c as Map<String, dynamic>];

  Future<dynamic> _get(TrelloCredentials credentials, String path, Map<String, String> query) async {
    final uri = Uri.https('api.trello.com', path, {...query, 'key': credentials.apiKey, 'token': credentials.token});
    final http.Response response;
    try {
      response = await _http.get(uri, headers: {'Accept': 'application/json'}).timeout(_timeout);
    } on TimeoutException {
      throw const TrelloException('Trello took too long to respond.');
    } on IOException {
      throw const TrelloException("Can't reach Trello. Check your internet connection.");
    } on http.ClientException {
      throw const TrelloException("Can't reach Trello. Check your internet connection.");
    }

    final status = response.statusCode;
    final body = utf8.decode(response.bodyBytes);
    if (status >= 200 && status < 300) {
      try {
        return jsonDecode(body);
      } on FormatException {
        throw const TrelloException("Trello sent something unexpected.");
      }
    }
    // Trello answers errors in plain text ("invalid key", "invalid token"…).
    final text = body.trim().toLowerCase();
    throw TrelloException(
      switch (status) {
        401 when text.contains('key') => 'Trello rejected the API key.',
        401 => 'Trello rejected the token. Get a new one and try again.',
        403 => "Trello doesn't allow this token to see that.",
        404 => "Trello couldn't find that.",
        429 => 'Trello is rate limiting requests. Try again in a minute.',
        _ => body.trim().isEmpty ? 'Trello request failed ($status).' : 'Trello: ${body.trim()}',
      },
      statusCode: status,
    );
  }
}
