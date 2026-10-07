import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/format.dart';
import '../../core/trello_client.dart';
import '../../models/trello.dart';
import '../../state/trello_controller.dart';
import '../../widgets/common.dart';

/// Trello's label colours (base names; "_dark"/"_light" variants map here).
Color trelloLabelColor(String color) => switch (color.split('_').first) {
      'green' => const Color(0xFF4BCE97),
      'yellow' => const Color(0xFFE2B203),
      'orange' => const Color(0xFFFAA53D),
      'red' => const Color(0xFFF87168),
      'purple' => const Color(0xFF9F8FEF),
      'blue' => const Color(0xFF579DFF),
      'sky' => const Color(0xFF6CC3E0),
      'lime' => const Color(0xFF94C748),
      'pink' => const Color(0xFFE774BB),
      'black' => const Color(0xFF8590A2),
      _ => const Color(0xFF8590A2),
    };

/// Cards sharing a list (a board column).
class _ListGroup {
  _ListGroup(this.key, this.board, this.list);

  final String key;
  final String board;
  final String list;
  final List<TrelloCard> cards = [];
}

/// Search box, board filter, and cards grouped by board and list
/// (collapsible), with an optional header. Used by the picker and the
/// Trello cards page.
class TrelloCardList extends StatefulWidget {
  const TrelloCardList({
    super.key,
    required this.trello,
    required this.onSelected,
    this.title,
    this.trailing,
  });

  final TrelloController trello;
  final ValueChanged<TrelloCard> onSelected;
  final String? title;
  final Widget? trailing;

  @override
  State<TrelloCardList> createState() => TrelloCardListState();
}

class TrelloCardListState extends State<TrelloCardList> {
  final _query = TextEditingController();
  Timer? _debounce;
  List<TrelloCard>? _cards;
  String? _error;
  bool _loading = false;
  int _searchId = 0;

  @override
  void initState() {
    super.initState();
    _search(refresh: true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  /// Reloads from Trello, keeping the search text and filter.
  void refresh() => _search(refresh: true);

  void _onTyped(String _) {
    _debounce?.cancel();
    // Matching is local once cards are loaded, so this can be quick.
    _debounce = Timer(const Duration(milliseconds: 150), _search);
  }

  Future<void> _search({bool refresh = false}) async {
    _debounce?.cancel();
    final id = ++_searchId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cards = await widget.trello.findCards(_query.text, refresh: refresh);
      if (!mounted || id != _searchId) return;
      setState(() => _cards = cards);
    } on TrelloException catch (e) {
      if (!mounted || id != _searchId) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted && id == _searchId) setState(() => _loading = false);
    }
  }

  bool get _searching => _query.text.trim().isNotEmpty;

  List<_ListGroup> _group(List<TrelloCard> cards) {
    final groups = <String, _ListGroup>{};
    for (final card in cards) {
      final key = '${card.boardId}/${card.listId}';
      groups.putIfAbsent(key, () => _ListGroup(key, card.boardName, card.listName)).cards.add(card);
    }
    return groups.values.toList(); // Cards arrive sorted by board, then list.
  }

  bool _isExpanded(_ListGroup group, int total) {
    if (_searching || total <= 8) return true;
    return widget.trello.groupExpanded[group.key] ?? true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final loaded = _cards;
    final boardFilter = widget.trello.boardFilter;
    final cards = loaded?.where((c) => boardFilter.isEmpty || boardFilter.contains(c.boardId)).toList();
    final boards = <String, String>{for (final c in loaded ?? const <TrelloCard>[]) c.boardId: c.boardName};
    final multipleBoards = boards.length > 1;

    Widget body;
    if (_error != null) {
      body = ErrorState(message: _error!, onRetry: refresh);
    } else if (cards == null) {
      body = const SizedBox.shrink();
    } else if (cards.isEmpty) {
      body = EmptyState(
        icon: Icons.search_off,
        message: _searching
            ? 'No Trello cards match "${_query.text.trim()}".'
            : loaded!.isNotEmpty
                ? 'No cards on the chosen boards.'
                : widget.trello.scope == TrelloCardScope.mine
                    ? 'No open Trello cards are assigned to you.'
                    : 'No open cards on your boards.',
      );
    } else {
      final groups = _group(cards);
      body = ListView(
        padding: const EdgeInsets.only(bottom: 8),
        children: [
          for (final group in groups) ...[
            _GroupHeader(
              title: multipleBoards ? '${group.board} · ${group.list}' : group.list,
              count: group.cards.length,
              expanded: _isExpanded(group, cards.length),
              onTap: _searching || cards.length <= 8
                  ? null
                  : () => setState(() {
                        widget.trello.groupExpanded[group.key] = !_isExpanded(group, cards.length);
                      }),
            ),
            if (_isExpanded(group, cards.length))
              for (var i = 0; i < group.cards.length; i++) ...[
                if (i > 0) const Divider(height: 1, indent: 12, endIndent: 12),
                _CardTile(card: group.cards[i], onTap: () => widget.onSelected(group.cards[i])),
              ],
          ],
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 4, 0),
            child: Row(
              children: [
                Text(widget.title!, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                if (cards != null && cards.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  _CountPill(count: cards.length),
                ],
                const Spacer(),
                if (widget.trailing != null) widget.trailing!,
              ],
            ),
          ),
        Padding(
          padding: EdgeInsets.fromLTRB(12, widget.title != null ? 2 : 10, 12, 6),
          child: TextField(
            controller: _query,
            autofocus: true,
            onChanged: _onTyped,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              hintText: 'Search title, description, list or label',
              prefixIcon: const Icon(Icons.search, size: 18),
              prefixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 34),
              suffixIcon: widget.title == null && cards != null
                  ? Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: Center(widthFactor: 1, child: _CountPill(count: cards.length)),
                    )
                  : null,
            ),
          ),
        ),
        if (multipleBoards)
          SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              children: [
                _BoardFilter(
                  boards: boards,
                  selected: boardFilter,
                  onToggle: (id) => setState(() {
                    if (!boardFilter.remove(id)) boardFilter.add(id);
                  }),
                ),
                if (boardFilter.isNotEmpty) ...[
                  const SizedBox(width: 2),
                  TextButton(
                    onPressed: () => setState(boardFilter.clear),
                    child: const Text('Clear'),
                  ),
                ],
              ],
            ),
          ),
        SizedBox(height: 2, child: _loading ? const LinearProgressIndicator(minHeight: 2) : null),
        Divider(height: 1, color: scheme.outlineVariant),
        Expanded(child: body),
      ],
    );
  }
}

class _CountPill extends StatelessWidget {
  const _CountPill({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text('$count', style: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600)),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.title, required this.count, required this.expanded, required this.onTap});

  final String title;
  final int count;
  final bool expanded;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 7, 12, 7),
          child: Row(
            children: [
              AnimatedRotation(
                turns: expanded ? 0 : -0.25,
                duration: const Duration(milliseconds: 150),
                child: Icon(Icons.expand_more, size: 18, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(width: 4),
              Icon(Icons.view_column_outlined, size: 14, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              _CountPill(count: count),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Boards · 2 ▾" checklist.
class _BoardFilter extends StatelessWidget {
  const _BoardFilter({required this.boards, required this.selected, required this.onToggle});

  final Map<String, String> boards;
  final Set<String> selected;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final active = selected.isNotEmpty;
    final fg = active ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;
    final entries = boards.entries.toList()..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()));
    return MenuAnchor(
      menuChildren: [
        for (final board in entries)
          MenuItemButton(
            closeOnActivate: false,
            leadingIcon: Icon(
              selected.contains(board.key) ? Icons.check_box : Icons.check_box_outline_blank,
              size: 18,
              color: selected.contains(board.key) ? scheme.primary : scheme.onSurfaceVariant,
            ),
            onPressed: () => onToggle(board.key),
            child: Text(board.value.isEmpty ? 'Untitled board' : board.value),
          ),
      ],
      builder: (context, menu, _) => Material(
        color: active ? scheme.secondaryContainer : Colors.transparent,
        shape: StadiumBorder(side: BorderSide(color: active ? Colors.transparent : scheme.outlineVariant)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: () => menu.isOpen ? menu.close() : menu.open(),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 3, 4, 3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  active ? 'Boards · ${selected.length}' : 'Boards',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: fg,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
                Icon(Icons.arrow_drop_down, size: 18, color: fg),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Due date as a small badge: red when overdue, green when done.
class TrelloDueBadge extends StatelessWidget {
  const TrelloDueBadge({super.key, required this.due, required this.complete});

  final DateTime due;
  final bool complete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final local = due.toLocal();
    final days = dateOnly(local).difference(dateOnly(DateTime.now())).inDays;
    final color = complete
        ? const Color(0xFF22A06B)
        : days < 0
            ? scheme.error
            : days <= 1
                ? const Color(0xFFE2B203)
                : scheme.onSurfaceVariant;
    final text = days == 0
        ? 'Due today'
        : days == 1
            ? 'Due tomorrow'
            : 'Due ${DateFormat('MMM d').format(local)}';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(complete ? Icons.check_circle_outline : Icons.schedule, size: 12, color: color),
        const SizedBox(width: 2),
        Text(text, style: theme.textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

/// A label as a coloured dot and its name.
class TrelloLabelChip extends StatelessWidget {
  const TrelloLabelChip({super.key, required this.label});

  final TrelloLabel label;

  @override
  Widget build(BuildContext context) {
    final color = trelloLabelColor(label.color);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: label.name.isEmpty ? 0 : 5, vertical: 1),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(4)),
      child: label.name.isEmpty
          ? SizedBox(width: 20, height: 8, child: DecoratedBox(decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4))))
          : Text(
              label.name,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(fontSize: 10, fontWeight: FontWeight.w600),
            ),
    );
  }
}

/// One card: labels and due date, then the title and a short description.
class _CardTile extends StatelessWidget {
  const _CardTile({required this.card, required this.onTap});

  final TrelloCard card;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final description = card.shortDescription;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 9),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (card.labels.isNotEmpty || card.due != null || card.idShort != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(
                  children: [
                    if (card.idShort != null) ...[
                      Text(
                        '#${card.idShort}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    Expanded(
                      child: Wrap(
                        spacing: 4,
                        runSpacing: 2,
                        children: [for (final l in card.labels.take(3)) TrelloLabelChip(label: l)],
                      ),
                    ),
                    if (card.due != null) TrelloDueBadge(due: card.due!, complete: card.dueComplete),
                  ],
                ),
              ),
            Text(
              card.name.isEmpty ? '(no title)' : card.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, height: 1.25),
            ),
            if (description.isNotEmpty) ...[
              const SizedBox(height: 1),
              Text(
                description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
