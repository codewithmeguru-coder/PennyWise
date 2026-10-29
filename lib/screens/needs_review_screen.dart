import 'package:flutter/material.dart';

import '../accounts/account_balances.dart';
import '../accounts/account_repository.dart';
import '../accounts/money_account.dart';
import '../categorization/category_suggester.dart';
import '../data/transaction_store.dart';
import '../maintenance/account_assignment.dart';
import '../maintenance/sim_backfill.dart';
import '../models/fuliza_link.dart';
import '../models/transaction_category.dart';
import '../models/transaction_model.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';
import '../utils/transaction_search.dart';
import '../widgets/empty_state.dart';
import '../widgets/search_field.dart';
import '../widgets/transaction_tile.dart';
import 'sim_backfill_screen.dart';

/// Transactions PennyWise couldn't categorize ("Uncategorized" or
/// "Uncategorized income"), newest first, to fix one at a time.
///
/// Picking a category only changes that transaction's category: [onCorrect]
/// saves it and learns from it (see `HomeShell`), the same way as editing it
/// in the form. The list follows [store], so a fixed one disappears as soon
/// as it is saved.
///
/// With [accounts], a second tab lists SMS records that have no account:
/// each can be given one (its known SIM's account in one tap, or one the
/// user picks), after seeing how each account card would change. Only the
/// account changes, never the category or type.
class NeedsReviewScreen extends StatefulWidget {
  const NeedsReviewScreen({
    super.key,
    required this.store,
    required this.onCorrect,
    this.accounts,
    this.onAssign,
    this.onEdit,
    this.simBackfill,
  });

  final TransactionStore store;

  /// The user's accounts; null hides the Account tab.
  final AccountStore? accounts;

  /// Saves [after] (= [before] with an account) and offers Undo.
  final Future<void> Function(TransactionModel before, TransactionModel after)?
  onAssign;

  /// Opens the edit form (for moves that need two accounts).
  final ValueChanged<TransactionModel>? onEdit;

  /// "Fill in SIMs from your messages" (previewed; nothing written before
  /// the user confirms there).
  final SimBackfill? simBackfill;

  /// Saves [before] with [categoryId] as its category.
  final Future<void> Function(TransactionModel before, String categoryId)
  onCorrect;

  static bool needsReview(TransactionModel t) =>
      t.categoryId == CategorySuggester.uncategorized ||
      t.categoryId == CategorySuggester.uncategorizedIncome;

  /// The transactions to review, newest first.
  static List<TransactionModel> pending(List<TransactionModel> all) =>
      all.where(needsReview).toList()..sort((a, b) => b.date.compareTo(a.date));

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
    final accounts = widget.accounts;
    if (accounts == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Needs review')),
        body: _categoryTab(),
      );
    }
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Needs review'),
          bottom: TabBar(
            tabs: [
              ListenableBuilder(
                listenable: widget.store,
                builder: (context, _) => Tab(
                  text:
                      'Category '
                      '(${NeedsReviewScreen.pending(widget.store.transactions).length})',
                ),
              ),
              ListenableBuilder(
                listenable: widget.store,
                builder: (context, _) => Tab(
                  text:
                      'Account '
                      '(${AccountAssignment.pending(widget.store.transactions).length})',
                ),
              ),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _categoryTab(),
            _AccountTab(
              store: widget.store,
              accounts: accounts,
              onAssign: widget.onAssign,
              onEdit: widget.onEdit,
              simBackfill: widget.simBackfill,
            ),
          ],
        ),
      ),
    );
  }

  Widget _categoryTab() {
    return ListenableBuilder(
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
        final links = FulizaLinks(store.transactions);
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
                  paidWithFuliza: links.paidWithFuliza(items[i - 1]),
                  onTap: () => _pick(context, items[i - 1]),
                ),
        );
      },
    );
  }
}

/// SMS records with no account, and giving them one.
class _AccountTab extends StatelessWidget {
  const _AccountTab({
    required this.store,
    required this.accounts,
    this.onAssign,
    this.onEdit,
    this.simBackfill,
  });

  final TransactionStore store;
  final AccountStore accounts;
  final Future<void> Function(TransactionModel, TransactionModel)? onAssign;
  final ValueChanged<TransactionModel>? onEdit;
  final SimBackfill? simBackfill;

  Future<void> _open(BuildContext context, TransactionModel t) async {
    if (!AccountAssignment.assignable(t)) {
      // A move between the user's own accounts: with the SIM recorded, both
      // sides follow from it (that SIM's M-Pesa and its Ziidi or Fuliza).
      // Without it, or for any other move, the form asks for both.
      final pair = AccountAssignment.pairForSim(
          t.type, t.id, t.simSlot, accounts);
      final after = pair == null
          ? null
          : t.withAccount(pair.from.id, toAccountId: pair.to.id);
      final effect = after == null
          ? null
          : AssignmentWording.ofAfter(
              t, after, accounts.all, store.transactions);
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (context) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.description,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                if (pair == null)
                  const Text(
                    'This moves money between two of your accounts '
                    '(a transfer, savings or a loan repayment), so it needs '
                    'both. Open it in the form to choose them.',
                  )
                else ...[
                  Text(
                    'This message came to SIM ${t.simSlot! + 1}, so it moved '
                    'money from ${pair.from.name} to ${pair.to.name}.',
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${AssignmentWording.historyLabel} ${effect!.history}\n'
                    '${AssignmentWording.cardsLabel} ${effect.cards}',
                    key: const Key('assign-pair-effect'),
                    style: const TextStyle(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    AssignmentWording.whatChanges,
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                ],
                const SizedBox(height: 12),
                if (pair != null && onAssign != null)
                  FilledButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      onAssign!(t, after!);
                    },
                    child: Text('Use ${pair.from.name} → ${pair.to.name}'),
                  ),
                if (onEdit != null)
                  (pair == null ? FilledButton.new : OutlinedButton.new)(
                    onPressed: () {
                      Navigator.of(context).pop();
                      onEdit!(t);
                    },
                    child: const Text('Open in the form'),
                  ),
              ],
            ),
          ),
        ),
      );
      return;
    }
    final suggested = AccountAssignment.forKnownSim(t, accounts);
    final choices = [
      for (final a in accounts.active)
        if (a.kind == AccountKind.mobileMoney ||
            a.kind == AccountKind.bank ||
            a.kind == AccountKind.cash)
          a,
    ];
    final picked = await showModalBottomSheet<MoneyAccount>(
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
                'Account for "${t.description}"',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                suggested == null
                    ? 'The SIM wasn\'t recorded for this message. Pick the '
                          'account it came from.'
                    : 'This message came to SIM ${t.simSlot! + 1}.',
                style: const TextStyle(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 4),
              const Text(
                AssignmentWording.whatChanges,
                key: Key('assign-what-changes'),
                style: TextStyle(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 12),
              for (final a in [
                ?suggested,
                for (final c in choices)
                  if (c.id != suggested?.id) c,
              ])
                _AccountChoice(
                  account: a,
                  suggested: a.id == suggested?.id,
                  effect: AssignmentWording.of(
                    t,
                    a,
                    accounts.all,
                    store.transactions,
                  ),
                  onTap: () => Navigator.of(context).pop(a),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || onAssign == null) return;
    // Only the account is set (an existing SIM is kept), so Undo can put
    // the record back exactly.
    await onAssign!(t, t.withAccount(picked.id));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([store, accounts]),
      builder: (context, _) {
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
        final items = AccountAssignment.pending(store.transactions);
        final links = FulizaLinks(store.transactions);
        final backfill = simBackfill;
        return ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Text(
                items.isEmpty
                    ? 'Every SMS transaction has an account.'
                    : 'These SMS transactions have no account, so no account '
                          'card counts them. Tap one to choose its account; '
                          'you\'ll see how each card would change first.',
              ),
            ),
            if (backfill != null && items.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => SimBackfillScreen(backfill: backfill),
                    ),
                  ),
                  icon: const Icon(Icons.sim_card_outlined),
                  label: const Text('Fill in SIMs from your messages…'),
                ),
              ),
            for (final t in items) ...[
              TransactionTile(
                transaction: t,
                paidWithFuliza: links.paidWithFuliza(t),
                onTap: () => _open(context, t),
              ),
              const Divider(height: 1, indent: 72),
            ],
          ],
        );
      },
    );
  }
}

class _AccountChoice extends StatelessWidget {
  const _AccountChoice({
    required this.account,
    required this.suggested,
    required this.effect,
    required this.onTap,
  });

  final MoneyAccount account;
  final bool suggested;
  final ({String history, String cards}) effect;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(
          suggested ? Icons.sim_card_rounded : Icons.account_balance_wallet,
          color: AppColors.primary,
        ),
        title: Text(suggested ? 'Use ${account.name}' : account.name),
        subtitle: Text(
          '${AssignmentWording.historyLabel} ${effect.history}\n'
          '${AssignmentWording.cardsLabel} ${effect.cards}',
          key: Key('assign-effect-${account.id}'),
        ),
        onTap: onTap,
      ),
    );
  }
}

/// The single-assignment sheet's wording: the transaction's effect on the
/// account's past totals kept apart from the change to the balance its card
/// shows (as in Fill in SIMs). Both come from [AccountAssignment].
class AssignmentWording {
  AssignmentWording._();

  static const whatChanges =
      'Assigning an account only records which account this transaction '
      'belongs to. It doesn\'t add, remove or move money, and the amount, '
      'category, type, fee, date and code stay the same.';

  static const historyLabel = 'Past total:';
  static const cardsLabel = 'Card balance:';

  static String _amounts(Map<MoneyAccount, double> m) => [
    for (final e in m.entries)
      '${e.key.name} ${e.value > 0 ? '+' : ''}${Formatters.currency(e.value)}',
  ].join(' · ');

  /// What saving [after] in place of [t] does, as [of] says it, for a move
  /// that sets both of its accounts.
  static ({String history, String cards}) ofAfter(
    TransactionModel t,
    TransactionModel after,
    List<MoneyAccount> accounts,
    List<TransactionModel> all,
  ) {
    final history = AccountAssignment.impact(accounts, all, [after]);
    final cards = AccountAssignment.cardChange(accounts, all, [after]);
    return (
      history: history.isEmpty
          ? 'no change.'
          : '${_amounts(history)} (not a balance change)',
      cards: cards.isEmpty ? 'no change.' : _amounts(cards),
    );
  }

  /// What giving [t] account [a] does: to the accounts' past income minus
  /// spending ([AccountAssignment.impact]) and to the balances their cards
  /// show ([AccountAssignment.cardChange]).
  static ({String history, String cards}) of(
    TransactionModel t,
    MoneyAccount a,
    List<MoneyAccount> accounts,
    List<TransactionModel> all,
  ) {
    final after = [t.withAccount(a.id)];
    final history = AccountAssignment.impact(accounts, all, after);
    final cards = AccountAssignment.cardChange(accounts, all, after);
    final String historyText;
    if (history.isNotEmpty) {
      historyText = '${_amounts(history)} (not a balance change)';
    } else if (AccountBalance.belongs(a, t)) {
      historyText = 'no change; already counted through its SIM.';
    } else if (a.openingDate != null && t.date.isBefore(a.openingDate!)) {
      historyText = 'no change; older than this account\'s starting balance.';
    } else {
      historyText = 'no change.';
    }
    final String cardsText;
    if (cards.isNotEmpty) {
      cardsText = _amounts(cards);
    } else if (history.isEmpty) {
      cardsText = 'no change.';
    } else {
      cardsText =
          'no change; the card uses a newer M-Pesa balance message, which '
          'already includes this transaction.';
    }
    return (history: historyText, cards: cardsText);
  }
}
