import 'package:flutter/material.dart';

import '../categorization/category_suggester.dart';
import '../data/transaction_store.dart';
import '../models/transaction_category.dart';
import '../models/transaction_model.dart';
import '../utils/transaction_search.dart';
import '../widgets/empty_state.dart';
import '../widgets/search_field.dart';
import '../widgets/transaction_tile.dart';

/// Transactions PennyWise couldn't categorize ("Uncategorized" or
/// "Uncategorized income"), newest first, to fix one at a time.
///
/// Picking a category only changes that transaction's category: [onCorrect]
/// saves it and learns from it (see `HomeShell`), the same way as editing it
/// in the form. The list follows [store], so a fixed one disappears as soon
/// as it is saved.
class NeedsReviewScreen extends StatefulWidget {
  const NeedsReviewScreen({
    super.key,
    required this.store,
    required this.onCorrect,
  });

  final TransactionStore store;

  /// Saves [before] with [categoryId] as its category.
  final Future<void> Function(TransactionModel before, String categoryId)
      onCorrect;

  static bool needsReview(TransactionModel t) =>
      t.categoryId == CategorySuggester.uncategorized ||
      t.categoryId == CategorySuggester.uncategorizedIncome;

  /// The transactions to review, newest first.
  static List<TransactionModel> pending(List<TransactionModel> all) =>
      all.where(needsReview).toList()
        ..sort((a, b) => b.date.compareTo(a.date));

  @override
  State<NeedsReviewScreen> createState() => _NeedsReviewScreenState();
}

class _NeedsReviewScreenState extends State<NeedsReviewScreen> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _pick(BuildContext context, TransactionModel t) async {
    final choices = DefaultCategories.forType(t.type)
        .where((c) => !c.id.startsWith('uncategorized'))
        .toList();
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Category for "${t.description}"',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in choices)
                    ActionChip(
                      avatar: Icon(c.icon, size: 18),
                      label: Text(c.name),
                      onPressed: () => Navigator.of(context).pop(c.id),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null) return;
    await widget.onCorrect(t, picked);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Needs review')),
      body: ListenableBuilder(
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
          final waiting = NeedsReviewScreen.pending(store.transactions);
          if (waiting.isEmpty) {
            return const EmptyState(
              icon: Icons.task_alt_rounded,
              title: 'All caught up',
              message: 'Every transaction has a category.',
            );
          }
          final items = TransactionSearch.filter(waiting, _query);
          return ListView.separated(
            padding: const EdgeInsets.only(bottom: 32),
            itemCount: items.length + 1,
            separatorBuilder: (_, i) => i == 0
                ? const SizedBox.shrink()
                : const Divider(height: 1, indent: 72),
            itemBuilder: (context, i) => i == 0
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SearchField(
                          controller: _search,
                          hint: 'Search name, amount, code',
                          onChanged: (q) => setState(() => _query = q),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          items.isEmpty
                              ? 'Nothing waiting matches "${_query.trim()}".'
                              : 'Tap one to pick its category. For an M-Pesa '
                                  'message, PennyWise remembers it for that '
                                  'sender too.',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  )
                : TransactionTile(
                    transaction: items[i - 1],
                    onTap: () => _pick(context, items[i - 1]),
                  ),
          );
        },
      ),
    );
  }
}
