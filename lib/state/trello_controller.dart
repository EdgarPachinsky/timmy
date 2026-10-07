import 'package:flutter/foundation.dart';

import '../core/storage.dart';
import '../core/trello_client.dart';
import '../models/trello.dart';

/// Which cards the Trello lists show.
enum TrelloCardScope {
  /// Open cards assigned to you.
  mine,

  /// Every open card on your open boards.
  allBoards,
}

/// The current user's Trello connection, and the card search the tracker uses.
class TrelloController extends ChangeNotifier {
  TrelloController({
    required TrelloClient client,
    required AppStorage storage,
    required int userId,
  })  : _client = client,
        _storage = storage,
        _userId = userId {
    _load();
  }

  final TrelloClient _client;
  final AppStorage _storage;
  final int _userId;

  TrelloCredentials? _credentials;
  TrelloMember? _member;
  TrelloCardScope _scope = TrelloCardScope.mine;
  bool _linkInDescription = false;
  bool _connecting = false;

  /// Cards (and boards) from the last load, reused briefly while typing.
  List<TrelloCard>? _cache;
  DateTime? _cachedAt;
  static const _cacheAge = Duration(minutes: 2);

  /// Board filter for the card lists (board ids), and which list groups are
  /// open; kept while the app runs.
  final Set<String> boardFilter = {};
  final Map<String, bool> groupExpanded = {};

  bool get isConnected => _credentials != null;
  bool get connecting => _connecting;
  TrelloMember? get member => _member;
  TrelloCardScope get scope => _scope;

  /// Put the card's link in the entry description when picking it.
  bool get linkInDescription => _linkInDescription;

  void _load() {
    final saved = _storage.trelloSettings(_userId);
    if (saved == null) return;
    try {
      final creds = saved['credentials'];
      if (creds is Map<String, dynamic>) _credentials = TrelloCredentials.fromJson(creds);
      final member = saved['member'];
      if (member is Map<String, dynamic>) _member = TrelloMember.fromJson(member);
    } catch (_) {
      _credentials = null;
      _member = null;
    }
    _scope = TrelloCardScope.values.firstWhere(
      (s) => s.name == saved['scope'],
      orElse: () => TrelloCardScope.mine,
    );
    _linkInDescription = saved['linkInDescription'] as bool? ?? false;
  }

  Future<void> _save() => _storage.saveTrelloSettings(_userId, {
        'credentials': _credentials?.toJson(),
        'member': _member?.toJson(),
        'scope': _scope.name,
        'linkInDescription': _linkInDescription,
      });

  /// Checks the key and token with Trello and saves them if they work.
  /// Throws [TrelloException] otherwise.
  Future<void> connect({required String apiKey, required String token}) async {
    final key = apiKey.trim();
    final tok = token.trim();
    if (key.isEmpty) throw const TrelloException('Paste your Trello API key.');
    if (tok.isEmpty) throw const TrelloException('Paste the token Trello gave you.');
    final credentials = TrelloCredentials(apiKey: key, token: tok);
    _connecting = true;
    notifyListeners();
    try {
      _member = await _client.me(credentials);
      _credentials = credentials;
      _cache = null;
      await _save();
    } finally {
      _connecting = false;
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    _credentials = null;
    _member = null;
    _cache = null;
    boardFilter.clear();
    notifyListeners();
    await _save();
  }

  Future<void> setScope(TrelloCardScope scope) async {
    _scope = scope;
    _cache = null;
    notifyListeners();
    await _save();
  }

  Future<void> setLinkInDescription(bool value) async {
    _linkInDescription = value;
    notifyListeners();
    await _save();
  }

  /// Cards for the picker and the Trello cards page: those whose title,
  /// description, board, list or labels contain [query]. [refresh] skips the
  /// cached cards.
  Future<List<TrelloCard>> findCards(String query, {bool refresh = false}) async {
    final credentials = _credentials;
    if (credentials == null) throw const TrelloException('Connect Trello in Settings first.');

    var cards = _cache;
    if (refresh || cards == null || DateTime.now().difference(_cachedAt!) > _cacheAge) {
      final boards = await _client.boards(credentials);
      final byId = {for (final b in boards) b.id: b};
      final raw = switch (_scope) {
        TrelloCardScope.mine => await _client.myCards(credentials),
        TrelloCardScope.allBoards => [
            for (final list in await Future.wait([
              for (final b in boards.take(TrelloClient.maxBoards)) _client.boardCards(credentials, b.id),
            ]))
              ...list,
          ],
      };
      cards = [for (final c in raw) TrelloCard.fromJson(c, byId)]..sort(_byBoardListDue);
      _cache = cards;
      _cachedAt = DateTime.now();
    }
    return [for (final c in cards) if (trelloCardContains(c, query)) c];
  }

  /// Board, then list order, then soonest due, then most recently active.
  static int _byBoardListDue(TrelloCard a, TrelloCard b) {
    var c = a.boardName.toLowerCase().compareTo(b.boardName.toLowerCase());
    if (c != 0) return c;
    c = a.listIndex.compareTo(b.listIndex);
    if (c != 0) return c;
    if (a.due != null || b.due != null) {
      if (a.due == null) return 1;
      if (b.due == null) return -1;
      c = a.due!.compareTo(b.due!);
      if (c != 0) return c;
    }
    return (b.lastActivity ?? DateTime(0)).compareTo(a.lastActivity ?? DateTime(0));
  }

  /// What picking [card] puts in the tracker's title and description.
  ({String title, String? description}) taskFor(TrelloCard card) => (
        title: card.name,
        description: _linkInDescription && card.url.isNotEmpty ? card.url : null,
      );
}
