import 'jira.dart' show adfToRuns, JiraTextRun;

// Trello data used by Timmy: the saved connection, the member, boards and
// the cards offered as task titles.

class TrelloCredentials {
  const TrelloCredentials({required this.apiKey, required this.token});

  final String apiKey;
  final String token;

  factory TrelloCredentials.fromJson(Map<String, dynamic> json) => TrelloCredentials(
        apiKey: json['apiKey'] as String,
        token: json['token'] as String,
      );

  Map<String, dynamic> toJson() => {'apiKey': apiKey, 'token': token};
}

/// Where to send the user to get a token for [apiKey] (Trello shows it after
/// "Allow"). Read and write, so cards could be updated later.
Uri trelloAuthorizeUrl(String apiKey) => Uri.https('trello.com', '/1/authorize', {
      'expiration': 'never',
      'name': 'Timmy',
      'scope': 'read,write',
      'response_type': 'token',
      'key': apiKey.trim(),
    });

const trelloApiKeyPage = 'https://trello.com/power-ups/admin';

class TrelloMember {
  const TrelloMember({required this.id, required this.fullName, required this.username, this.email});

  final String id;
  final String fullName;
  final String username;
  final String? email;

  factory TrelloMember.fromJson(Map<String, dynamic> json) => TrelloMember(
        id: json['id'] as String? ?? '',
        fullName: json['fullName'] as String? ?? '',
        username: json['username'] as String? ?? '',
        email: json['email'] as String?,
      );

  Map<String, dynamic> toJson() => {'id': id, 'fullName': fullName, 'username': username, 'email': email};
}

class TrelloList {
  const TrelloList({required this.id, required this.name});

  final String id;
  final String name;
}

class TrelloBoard {
  const TrelloBoard({required this.id, required this.name, this.lists = const []});

  final String id;
  final String name;

  /// Open lists, in board order.
  final List<TrelloList> lists;

  factory TrelloBoard.fromJson(Map<String, dynamic> json) => TrelloBoard(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        lists: [
          for (final l in json['lists'] as List<dynamic>? ?? const [])
            if (l is Map) TrelloList(id: '${l['id']}', name: l['name'] as String? ?? ''),
        ],
      );
}

class TrelloLabel {
  const TrelloLabel({required this.name, required this.color});

  final String name;

  /// Trello's colour name ("green", "red_dark"…), or empty for no colour.
  final String color;
}

class TrelloCard {
  const TrelloCard({
    required this.id,
    required this.name,
    this.description = '',
    this.url = '',
    this.idShort,
    this.boardId = '',
    this.boardName = '',
    this.listId = '',
    this.listName = '',
    this.listIndex = 0,
    this.due,
    this.dueComplete = false,
    this.labels = const [],
    this.lastActivity,
    this.memberIds = const [],
  });

  final String id;

  /// The card's title.
  final String name;

  /// Raw description (Markdown).
  final String description;

  /// Short link to the card, e.g. https://trello.com/c/AbC123.
  final String url;

  /// Card number on its board ("#42").
  final int? idShort;
  final String boardId;
  final String boardName;
  final String listId;
  final String listName;

  /// Position of the list on its board, for ordering columns.
  final int listIndex;
  final DateTime? due;
  final bool dueComplete;
  final List<TrelloLabel> labels;
  final DateTime? lastActivity;
  final List<String> memberIds;

  /// The description as text and links (bare URLs become links).
  List<JiraTextRun> get descriptionRuns => adfToRuns(description);

  /// Description on one line, for previews.
  String get shortDescription => description
      .replaceAll(RegExp(r'[#*_`>]+'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// From `GET …/cards`; board and list names come from [boards].
  factory TrelloCard.fromJson(Map<String, dynamic> json, Map<String, TrelloBoard> boards) {
    final board = boards[json['idBoard']];
    final listId = json['idList'] as String? ?? '';
    final listIndex = board?.lists.indexWhere((l) => l.id == listId) ?? -1;
    return TrelloCard(
      id: json['id'] as String? ?? '',
      name: (json['name'] as String? ?? '').trim(),
      description: (json['desc'] as String? ?? '').trim(),
      url: json['shortUrl'] as String? ?? json['url'] as String? ?? '',
      idShort: (json['idShort'] as num?)?.toInt(),
      boardId: json['idBoard'] as String? ?? '',
      boardName: board?.name ?? '',
      listId: listId,
      listName: listIndex >= 0 ? board!.lists[listIndex].name : '',
      listIndex: listIndex < 0 ? 999 : listIndex,
      due: json['due'] is String ? DateTime.tryParse(json['due'] as String) : null,
      dueComplete: json['dueComplete'] as bool? ?? false,
      labels: [
        for (final l in json['labels'] as List<dynamic>? ?? const [])
          if (l is Map) TrelloLabel(name: l['name'] as String? ?? '', color: l['color'] as String? ?? ''),
      ],
      lastActivity: json['dateLastActivity'] is String ? DateTime.tryParse(json['dateLastActivity'] as String) : null,
      memberIds: [for (final m in json['idMembers'] as List<dynamic>? ?? const []) '$m'],
    );
  }
}

/// Whether [card]'s title, description, board, list or labels contain
/// [query] (any case).
bool trelloCardContains(TrelloCard card, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return true;
  return card.name.toLowerCase().contains(needle) ||
      card.description.toLowerCase().contains(needle) ||
      card.boardName.toLowerCase().contains(needle) ||
      card.listName.toLowerCase().contains(needle) ||
      card.labels.any((l) => l.name.toLowerCase().contains(needle)) ||
      (card.idShort != null && '#${card.idShort}' == needle);
}
