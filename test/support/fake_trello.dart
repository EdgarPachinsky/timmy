import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A scripted Trello API. Records the paths requested.
class FakeTrello {
  final requests = <Uri>[];
  bool rejectToken = false;

  static final cards = <String, List<Map<String, dynamic>>>{
    'b1': [
      {
        'id': 'c1',
        'idShort': 12,
        'name': 'Fix checkout button',
        'desc': 'The **Pay** button overlaps on mobile. See https://figma.com/file/x',
        'idBoard': 'b1',
        'idList': 'l2',
        'shortUrl': 'https://trello.com/c/AbC12',
        'due': '2026-10-01T09:00:00.000Z',
        'dueComplete': false,
        'labels': [
          {'name': 'Bug', 'color': 'red'},
        ],
        'dateLastActivity': '2026-10-06T10:00:00.000Z',
        'idMembers': ['m1'],
      },
      {
        'id': 'c2',
        'idShort': 3,
        'name': 'Write release notes',
        'desc': '',
        'idBoard': 'b1',
        'idList': 'l1',
        'shortUrl': 'https://trello.com/c/Rel3',
        'labels': <Object>[],
        'idMembers': <Object>[],
      },
    ],
    'b2': [
      {
        'id': 'c3',
        'idShort': 7,
        'name': 'Rotate server keys',
        'desc': 'Quarterly rotation',
        'idBoard': 'b2',
        'idList': 'l3',
        'shortUrl': 'https://trello.com/c/Ops7',
        'labels': <Object>[],
        'idMembers': ['m1'],
      },
    ],
  };

  late final MockClient client = MockClient((req) async {
    requests.add(req.url);
    if (rejectToken) return http.Response('invalid token', 401);
    Object body;
    switch (req.url.path) {
      case '/1/members/me':
        body = {'id': 'm1', 'fullName': 'Edgar Pachinsky', 'username': 'edgarp'};
      case '/1/members/me/boards':
        body = [
          {
            'id': 'b1',
            'name': 'Product',
            'lists': [
              {'id': 'l1', 'name': 'To Do'},
              {'id': 'l2', 'name': 'Doing'},
            ],
          },
          // No lists in the response: the client fetches them separately.
          {'id': 'b2', 'name': 'Ops'},
        ];
      case '/1/boards/b2/lists':
        body = [
          {'id': 'l3', 'name': 'Backlog'},
        ];
      case '/1/members/me/cards':
        body = [
          for (final list in cards.values)
            for (final c in list)
              if ((c['idMembers'] as List).contains('m1')) c,
        ];
      case final path when path.startsWith('/1/boards/') && path.endsWith('/cards/open'):
        body = cards[path.split('/')[3]] ?? <Object>[];
      default:
        return http.Response('not found', 404);
    }
    return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
  });
}
