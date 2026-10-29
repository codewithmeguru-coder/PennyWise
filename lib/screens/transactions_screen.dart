import 'package:flutter/material.dart';

import '../data/transaction_store.dart';
import '../models/transaction_model.dart';
import '../utils/transaction_search.dart';
import '../widgets/empty_state.dart';
import '../models/fuliza_link.dart';
import '../widgets/search_field.dart';
import 'needs_review_screen.dart';
import '../widgets/transaction_tile.dart';

/// Which transactions the list is showing.
enum _Filter { all, income, expense, moves }

/// Transactions tab: the full list with an All / Income / Expenses /
/// Transfers filter. "Expenses" includes debt repayments and refunds (which
/// change spending); "Transfers" covers transfers and savings, which move
/// your own money without earning or spending it.
class TransactionsScreen extends StatefulWidget {
  const TransactionsScreen({
    super.key,
    required this.store,
    required this.onTransactionTap,
    this.onTransactionLongPress,
    this.onOpenNeedsReview,
    this.onOpenMenu,
  });

  final TransactionStore store;

  /// Called when the user taps a transaction (opens the edit form).
  final ValueChanged<TransactionModel> onTransactionTap;

  /// Opens the Edit / Delete menu for a transaction.
  final ValueChanged<TransactionModel>? onTransactionLongPress;

  /// Opens the Needs review list; its button shows while any transaction
  /// still has no category.
  final VoidCallback? onOpenNeedsReview;

  /// Opens the side menu. When null, no ☰ button is shown.
  final VoidCallback? onOpenMenu;

  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends State<TransactionsScreen> {
  _Filter _filter = _Filter.all;
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<TransactionModel> _applyFilter(List<TransactionModel> items) {
    switch (_filter) {
      case _Filter.all:
        return items;
      case _Filter.income:
        return items.where((t) => t.isIncome).toList();
      case _Filter.expense:
        return items
            .where((t) => switch (t.type) {
                  TransactionType.expense ||
                  TransactionType.debtRepayment ||
                  TransactionType.refund =>
                    true,
                  _ => false,
                })
            .toList();
      case _Filter.moves:
        return items
            .where((t) => switch (t.type) {
                  TransactionType.transfer ||
                  TransactionType.savingsContribution ||
                  TransactionType.savingsWithdrawal =>
                    true,
                  _ => false,
                })
            .toList();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Transactions'),
        leading: widget.onOpenMenu == null
            ? null
            : IconButton(
                tooltip: 'Menu',
                icon: const Icon(Icons.menu_rounded),
                onPressed: widget.onOpenMenu,
              ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: SearchField(
              controller: _search,
              hint: 'Search name, amount, category, code',
              onChanged: (q) => setState(() => _query = q),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<_Filter>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: _Filter.all, label: Text('All')),
                  ButtonSegment(value: _Filter.income, label: Text('Income')),
                  ButtonSegment(
                    value: _Filter.expense,
                    label: Text('Expenses'),
                  ),
                  ButtonSegment(
                    value: _Filter.moves,
                    label: Text('Transfers'),
                  ),
                ],
                selected: {_filter},
                onSelectionChanged: (selection) =>
                    setState(() => _filter = selection.first),
              ),
            ),
          ),
          if (widget.onOpenNeedsReview case final open?)
            ListenableBuilder(
              listenable: widget.store,
              builder: (context, _) {
                final count = widget.store.isLoading
                    ? 0
                    : NeedsReviewScreen.pending(widget.store.transactions)
                        .length;
                if (count == 0) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonalIcon(
                      onPressed: open,
                      icon: const Icon(Icons.rule_rounded),
                      label: Text('Needs review ($count)'),
                    ),
                  ),
                );
              },
            ),
          Expanded(
            child: ListenableBuilder(
              listenable: widget.store,
              builder: (context, _) {
                final store = widget.store;
                if (store.isLoading) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (store.error != null) {
                  return EmptyState(
                    icon: Icons.cloud_off_rounded,
                    title: 'Couldn\'t load transactions',
                    message: store.error!,
                    actionLabel: 'Retry',
                    onAction: store.retry,
                  );
                }

                final items = TransactionSearch.filter(
                    _applyFilter(store.transactions), _query);
                final links = FulizaLinks(store.transactions);

                if (items.isEmpty) {
                  return EmptyState(
                    icon: Icons.search_off_rounded,
                    title: 'Nothing here',
                    message: _query.trim().isEmpty
                        ? 'No transactions match this filter yet.'
                        : 'No transactions match "${_query.trim()}".',
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.only(bottom: 96),
                  itemCount: items.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, indent: 72),
                  itemBuilder: (context, index) => TransactionTile(
                    transaction: items[index],
                    paidWithFuliza: links.paidWithFuliza(items[index]),
                    onTap: () => widget.onTransactionTap(items[index]),
                    onLongPress: widget.onTransactionLongPress == null
                        ? null
                        : () => widget.onTransactionLongPress!(items[index]),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
