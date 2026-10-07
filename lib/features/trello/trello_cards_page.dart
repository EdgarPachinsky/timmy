import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/links.dart';
import '../../models/trello.dart';
import '../../state/trello_controller.dart';
import '../jira/jira_rich_text.dart';
import 'trello_card_list.dart';

/// Searchable Trello cards grouped by board and list; resolves to the one
/// picked, or null.
Future<TrelloCard?> showTrelloCardPicker(BuildContext context, TrelloController trello) =>
    showDialog<TrelloCard>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(12),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640),
          child: TrelloCardList(
            trello: trello,
            title: 'Trello cards',
            trailing: IconButton(
              tooltip: 'Close',
              iconSize: 18,
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.pop(context),
            ),
            onSelected: (card) => Navigator.pop(context, card),
          ),
        ),
      ),
    );

/// Opens the Trello cards page. Pushed routes sit above the signed-in
/// providers, so the controller is handed over explicitly.
Future<void> openTrelloCards(BuildContext context) {
  final trello = context.read<TrelloController>();
  return Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => ChangeNotifierProvider.value(value: trello, child: const TrelloCardsPage()),
  ));
}

/// Browse and search your Trello cards; click one to read it in full.
class TrelloCardsPage extends StatefulWidget {
  const TrelloCardsPage({super.key});

  @override
  State<TrelloCardsPage> createState() => _TrelloCardsPageState();
}

class _TrelloCardsPageState extends State<TrelloCardsPage> {
  final _list = GlobalKey<TrelloCardListState>();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final trello = context.watch<TrelloController>();
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 44,
        titleSpacing: 0,
        centerTitle: false,
        title: Text('Trello cards', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            iconSize: 18,
            icon: const Icon(Icons.refresh),
            onPressed: () => _list.currentState?.refresh(),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: trello.isConnected
          ? TrelloCardList(
              key: _list,
              trello: trello,
              onSelected: (card) => showTrelloCardDetails(context, card),
            )
          : const Center(child: Text('Trello is not connected.')),
    );
  }
}

/// The whole card: board, list, labels, due date, title and description
/// with clickable links, plus Open in Trello.
Future<void> showTrelloCardDetails(BuildContext context, TrelloCard card) => showDialog<void>(
      context: context,
      builder: (context) => _CardDetails(card: card),
    );

class _CardDetails extends StatelessWidget {
  const _CardDetails({required this.card});

  final TrelloCard card;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final runs = card.descriptionRuns;
    final where = [
      if (card.boardName.isNotEmpty) card.boardName,
      if (card.listName.isNotEmpty) card.listName,
    ].join(' · ');

    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 680),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 4, 4),
              child: Row(
                children: [
                  Icon(Icons.view_column_outlined, size: 15, color: muted),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      where.isEmpty ? 'Trello card' : where,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (card.url.isNotEmpty)
                    IconButton(
                      tooltip: 'Open in Trello',
                      iconSize: 18,
                      icon: const Icon(Icons.open_in_new),
                      onPressed: () async {
                        final messenger = ScaffoldMessenger.maybeOf(context);
                        if (!await openExternal(card.url)) {
                          messenger?.showSnackBar(const SnackBar(content: Text("Couldn't open Trello.")));
                        }
                      },
                    ),
                  IconButton(
                    tooltip: 'Close',
                    iconSize: 18,
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
                child: SelectionArea(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        card.name.isEmpty ? '(no title)' : card.name,
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      if (card.labels.isNotEmpty || card.due != null) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            for (final l in card.labels) TrelloLabelChip(label: l),
                            if (card.due != null) TrelloDueBadge(due: card.due!, complete: card.dueComplete),
                          ],
                        ),
                      ],
                      const SizedBox(height: 12),
                      Divider(height: 1, color: scheme.outlineVariant),
                      const SizedBox(height: 12),
                      Text(
                        'Description',
                        style: theme.textTheme.labelMedium?.copyWith(color: muted, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 6),
                      if (runs.isEmpty)
                        Text(
                          'No description.',
                          style: theme.textTheme.bodyMedium?.copyWith(color: muted, fontStyle: FontStyle.italic),
                        )
                      else
                        JiraRichDescription(runs: runs, style: theme.textTheme.bodyMedium?.copyWith(height: 1.4)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
