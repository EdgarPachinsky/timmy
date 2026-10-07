import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timmy/core/storage.dart';
import 'package:timmy/core/trello_client.dart';
import 'package:timmy/models/trello.dart';
import 'package:timmy/state/trello_controller.dart';

import 'support/fake_trello.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const creds = TrelloCredentials(apiKey: 'k123', token: 't456');

  test('authorize URL asks for a never-expiring token for the key', () {
    final url = trelloAuthorizeUrl(' k123 ');
    expect(url.host, 'trello.com');
    expect(url.path, '/1/authorize');
    expect(url.queryParameters, {
      'expiration': 'never',
      'name': 'Timmy',
      'scope': 'read,write',
      'response_type': 'token',
      'key': 'k123',
    });
  });

  group('TrelloClient', () {
    test('sends key and token, and fills in missing board lists', () async {
      final fake = FakeTrello();
      final client = TrelloClient(httpClient: fake.client);
      final boards = await client.boards(creds);
      expect(fake.requests.first.queryParameters['key'], 'k123');
      expect(fake.requests.first.queryParameters['token'], 't456');
      expect(fake.requests.first.queryParameters['lists'], 'open');
      expect(boards.map((b) => b.name), ['Product', 'Ops']);
      expect(boards.last.lists.single.name, 'Backlog');
    });

    test('a bad token gets a clear message', () async {
      final fake = FakeTrello()..rejectToken = true;
      await expectLater(
        TrelloClient(httpClient: fake.client).me(creds),
        throwsA(isA<TrelloException>().having((e) => e.message, 'message', contains('token'))),
      );
    });

    test('cards get their board and list names', () async {
      final client = TrelloClient(httpClient: FakeTrello().client);
      final boards = {for (final b in await client.boards(creds)) b.id: b};
      final card = TrelloCard.fromJson((await client.myCards(creds)).first, boards);
      expect(card.name, 'Fix checkout button');
      expect(card.boardName, 'Product');
      expect(card.listName, 'Doing');
      expect(card.listIndex, 1);
      expect(card.url, 'https://trello.com/c/AbC12');
      expect(card.labels.single.name, 'Bug');
      expect(card.shortDescription, 'The Pay button overlaps on mobile. See https://figma.com/file/x');
      expect(card.descriptionRuns.where((r) => r.isLink).single.url, 'https://figma.com/file/x');
    });
  });

  group('TrelloController', () {
    late AppStorage storage;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      storage = AppStorage(await SharedPreferences.getInstance());
    });

    test('connect verifies and saves per user; disconnect forgets it', () async {
      final trello = TrelloController(client: TrelloClient(httpClient: FakeTrello().client), storage: storage, userId: 64);
      await trello.connect(apiKey: 'k123', token: 't456');
      expect(trello.member!.username, 'edgarp');
      expect(
        TrelloController(client: TrelloClient(), storage: storage, userId: 64).isConnected,
        isTrue,
      );
      expect(TrelloController(client: TrelloClient(), storage: storage, userId: 65).isConnected, isFalse);

      await trello.disconnect();
      expect(TrelloController(client: TrelloClient(), storage: storage, userId: 64).isConnected, isFalse);
    });

    test('a rejected token is not saved', () async {
      final trello = TrelloController(
        client: TrelloClient(httpClient: (FakeTrello()..rejectToken = true).client),
        storage: storage,
        userId: 64,
      );
      await expectLater(trello.connect(apiKey: 'k', token: 'bad'), throwsA(isA<TrelloException>()));
      expect(trello.isConnected, isFalse);
      expect(trello.connecting, isFalse);
    });

    test('findCards: assigned cards, "contains" search, then all boards', () async {
      final fake = FakeTrello();
      final trello = TrelloController(client: TrelloClient(httpClient: fake.client), storage: storage, userId: 64);
      await trello.connect(apiKey: 'k123', token: 't456');

      final mine = await trello.findCards('');
      // Sorted by board, then list order.
      expect(mine.map((c) => c.name), ['Rotate server keys', 'Fix checkout button']);
      expect((await trello.findCards('overlaps on')).single.id, 'c1'); // inside the description
      expect((await trello.findCards('backlog')).single.id, 'c3'); // list name
      expect((await trello.findCards('#12')).single.id, 'c1');

      await trello.setScope(TrelloCardScope.allBoards);
      final all = await trello.findCards('');
      expect(all.map((c) => c.id), containsAll(['c1', 'c2', 'c3']));
      expect(fake.requests.any((u) => u.path == '/1/boards/b1/cards/open'), isTrue);
    });

    test('taskFor uses the card name, with the link only when asked', () async {
      final trello = TrelloController(client: TrelloClient(httpClient: FakeTrello().client), storage: storage, userId: 64);
      await trello.connect(apiKey: 'k123', token: 't456');
      final card = (await trello.findCards('checkout')).single;
      expect(trello.taskFor(card).title, 'Fix checkout button');
      expect(trello.taskFor(card).description, isNull);
      await trello.setLinkInDescription(true);
      expect(trello.taskFor(card).description, 'https://trello.com/c/AbC12');
    });
  });
}
