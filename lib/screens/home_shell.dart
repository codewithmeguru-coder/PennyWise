import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../accounts/account_repository.dart';
import '../accounts/anchor_log.dart';
import '../accounts/money_account.dart';
import '../categorization/category_registry.dart';
import '../categorization/category_rule.dart';
import '../categorization/category_rule_repository.dart';
import '../data/budget_repository.dart';
import '../data/category_budget_repository.dart';
import '../data/data_exception.dart';
import '../data/transaction_store.dart';
import '../models/duplicate_finder.dart';
import '../models/month_selection.dart';
import '../models/transaction_category.dart';
import '../models/transaction_model.dart';
import '../services/auth_service.dart';
import '../services/avatar_store.dart';
import '../services/photo_picker.dart';
import '../maintenance/internal_transfer_fix.dart';
import '../maintenance/sim_backfill.dart';
import '../maintenance/ziidi_fix.dart';
import '../sms/fuliza_import.dart';
import '../sms/sms_import_service.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';
import '../widgets/app_drawer.dart';
import '../widgets/user_avatar.dart';
import 'accounts_screen.dart';
import 'add_transaction_screen.dart';
import 'budgets_screen.dart';
import 'dashboard_screen.dart';
import 'needs_review_screen.dart';
import 'settings_screen.dart';
import 'transactions_screen.dart';
import 'trends_screen.dart';

/// The main app frame: bottom navigation bar, the current tab, and the
/// "Add" button that opens [AddTransactionScreen]. It also performs the
/// writes the form asks for (add / update / delete).
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.store,
    required this.budgetRepository,
    this.categoryBudgets,
    this.categories,
    required this.categoryRules,
    required this.accounts,
    required this.smsService,
    this.fulizaImporter,
    this.ziidiFixer,
    this.moveFix,
    this.simBackfill,
    this.anchorKeeper,
    required this.user,
    required this.onSignOut,
    this.avatar,
    this.photoPicker,
  });

  final TransactionStore store;
  final BudgetRepository budgetRepository;

  /// Per-category monthly limits. Null: categories show spending only.
  final CategoryBudgetRepository? categoryBudgets;

  /// The user's own categories (see [CategoryRegistry]). Every tab rebuilds
  /// when they change, so a rename shows everywhere at once.
  final CategoryRegistry? categories;

  /// The user's own profile photo (Settings › Profile).
  final AvatarStore? avatar;

  /// Chooses that photo from the gallery.
  final PhotoPicker? photoPicker;

  /// Categories learned from the user's corrections.
  final CategoryRuleStore categoryRules;

  /// The user's own accounts (SIM 1 / SIM 2 M-Pesa, banks, cash...).
  final AccountStore accounts;

  /// Automatic transaction detection (Android only; idle elsewhere).
  final SmsImportService smsService;

  /// Settings › Fuliza history (see [FulizaImporter]).
  final FulizaImporter? fulizaImporter;

  /// Settings › Fix old Ziidi records (see [ZiidiFixer]).
  final ZiidiFixer? ziidiFixer;

  /// Settings › Fix moves between your SIMs (see [MoveFix]).
  final MoveFix? moveFix;

  /// Needs review › Account › "Fill in SIMs from your messages".
  final SimBackfill? simBackfill;

  /// Changes starting balances with an audit trail and Undo.
  final AnchorKeeper? anchorKeeper;
  final AppUser user;

  /// Signs the user out; [AuthGate] then shows the login screen.
  final Future<void> Function() onSignOut;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _currentIndex = 0;

  /// Lets the ☰ buttons inside the tabs open this Scaffold's drawer (the
  /// Transactions and Budgets tabs have Scaffolds of their own).
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  void _openMenu() => _scaffoldKey.currentState?.openDrawer();

  StreamSubscription<TransactionModel>? _detectedSub;

  /// The month Home's overview and Budgets show; moving it on one moves it
  /// on the other.
  final _month = MonthSelection();

  @override
  void initState() {
    super.initState();
    _detectedSub = widget.smsService.detected.listen(_showDetected);
  }

  @override
  void dispose() {
    _detectedSub?.cancel();
    _month.dispose();
    super.dispose();
  }

  /// In-app notification for a transaction found in an SMS, e.g.
  /// "New M-Pesa transaction detected: KSh 500.00 — Naivas", with a button
  /// to open it in the edit form (to fix the category, for example).
  ///
  /// If it looks like a transaction already entered by hand, the message
  /// says so and its button opens that manual entry to review (the SMS is
  /// saved either way; nothing is removed automatically).
  void _showDetected(TransactionModel t) {
    if (!mounted) return;
    final twin = DuplicateFinder.manualMatchesFor(t, widget.store.transactions)
        .firstOrNull;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('New ${t.source.label} transaction detected: '
              '${Formatters.currency(t.amount)} — ${t.description}'
              '${twin == null ? '' : '. Possible duplicate of '
                  '"${twin.description}".'}'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: twin == null ? 6 : 10),
          // A snack bar with a button stays until tapped unless told
          // otherwise; this one goes after its duration.
          persist: false,
          action: twin == null
              ? SnackBarAction(
                  label: 'Edit',
                  onPressed: () => _openTransactionForm(_latest(t)),
                )
              : SnackBarAction(
                  label: 'Review',
                  onPressed: () => _openTransactionForm(_latest(twin)),
                ),
        ),
      );
  }

  /// The current version of [t] from the store, in case it changed since
  /// the notification appeared.
  TransactionModel _latest(TransactionModel t) => widget.store.transactions
      .firstWhere((x) => x.id == t.id, orElse: () => t);

  void _openAccounts() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => AccountsScreen(
        accounts: widget.accounts,
        transactions: () => widget.store.transactions,
        keeper: widget.anchorKeeper,
      ),
    ));
  }

  /// First-time setup (and later): a starting balance for each account,
  /// typed or taken from its latest SMS, or skipped.
  Future<void> _setBalances() async {
    final result = await Navigator.of(context).push<List<MoneyAccount>>(
      MaterialPageRoute(
        builder: (_) => StartOverScreen(
          accounts: widget.accounts.all,
          transactions: widget.store.transactions,
          title: 'Set starting balances',
        ),
      ),
    );
    if (result == null || !mounted) return;
    try {
      for (final a in result) {
        final keeper = widget.anchorKeeper;
        if (keeper != null) {
          await keeper.change(a, reason: 'Starting balances');
        } else {
          await widget.accounts.save(a);
        }
      }
    } on DataException catch (e) {
      _showMessage(e.message);
      return;
    }
    _showMessage('Starting balances saved');
  }

  /// Month-by-month trends, ending at the month Home and Budgets show.
  void _openTrends() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => TrendsScreen(store: widget.store, month: _month),
    ));
  }

  void _openSettings() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SettingsScreen(
        smsService: widget.smsService,
        categoryRules: widget.categoryRules,
        categories: widget.categories,
        fulizaImporter: widget.fulizaImporter,
        ziidiFixer: widget.ziidiFixer,
        moveFix: widget.moveFix,
        transactions: widget.store,
        accounts: widget.accounts.all,
        user: widget.user,
        avatar: widget.avatar,
        photoPicker: widget.photoPicker,
      ),
    ));
  }

  /// Opens the form to add a transaction, or to edit [existing].
  Future<void> _openTransactionForm([TransactionModel? existing]) async {
    final result = await Navigator.of(context).push<TransactionFormResult>(
      MaterialPageRoute(
        builder: (_) => AddTransactionScreen(
          initial: existing,
          // All of them: the form hides hidden ones, but an entry that
          // already uses one must still open.
          accounts: widget.accounts.all,
          possibleDuplicatesOf: (draft) =>
              DuplicateFinder.smsMatchesFor(draft, widget.store.transactions),
        ),
      ),
    );
    if (result == null || !mounted) return;
    if (result is TransactionOpenExisting) {
      // Nothing saved; show the transaction it may repeat instead.
      await _openTransactionForm(_latest(result.transaction));
      return;
    }
    if (result is TransactionDeleted) {
      await _delete(result.transaction);
      return;
    }

    final t = result.transaction;
    final store = widget.store;
    final (Future<void> write, String done) = switch (result) {
      TransactionSaved() when existing == null =>
        (store.add(t), 'Added "${t.description}"'),
      TransactionSaved() => (store.update(t), 'Saved changes'),
      TransactionDeleted() ||
      TransactionOpenExisting() =>
        throw StateError('handled above'),
    };

    // The list updates straight away from Firestore's local cache, so confirm
    // now; if the server later rejects the write, show why.
    _showMessage(done);
    try {
      await write;
    } on DataException catch (e) {
      _showMessage(e.message);
      return;
    }
    if (existing != null) {
      await _learnFrom(existing, t);
    }
  }

  /// Needs review: saves [before] with only its category changed, then
  /// learns from it exactly as an edit in the form would.
  Future<void> _correctCategory(
      TransactionModel before, String categoryId) async {
    final after = before.withCategory(categoryId);
    try {
      await widget.store.update(after);
    } on DataException catch (e) {
      _showMessage(e.message);
      return;
    }
    _showMessage('Saved as ${DefaultCategories.byId(categoryId).name}');
    await _learnFrom(before, after);
  }

  /// Long press on a transaction: Edit or Delete. Nothing changes until an
  /// action is chosen (and, for Delete, confirmed).
  Future<void> _showActions(TransactionModel t) async {
    final action = await showModalBottomSheet<_RowAction>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(t.description,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${Formatters.currency(t.amount)} · '
                  '${Formatters.shortDate(t.date)}'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit'),
              onTap: () => Navigator.of(context).pop(_RowAction.edit),
            ),
            ListTile(
              leading:
                  Icon(Icons.delete_outline, color: context.colors.expense),
              title: Text('Delete',
                  style: TextStyle(color: context.colors.expense)),
              onTap: () => Navigator.of(context).pop(_RowAction.delete),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case _RowAction.edit:
        await _openTransactionForm(_latest(t));
      case _RowAction.delete:
        await _confirmAndDelete(_latest(t));
      case null:
        break;
    }
  }

  /// Deletes [t] after a confirmation naming it. A transfer is one record
  /// holding both sides, so it goes as a whole and no account is left half
  /// changed. An SMS entry stays in this phone's list of handled messages,
  /// so it isn't imported again.
  Future<void> _confirmAndDelete(TransactionModel t) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete transaction?'),
        content: Text(
          '${t.description} · ${Formatters.currency(t.amount)} · '
          '${Formatters.shortDate(t.date)}\n\n'
          '${t.isDetected ? "It won't be added again from its SMS. " : ''}'
          "This can't be undone.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: context.colors.expense),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _delete(t);
  }

  /// Deletes [t] and, once that has worked, offers Undo.
  Future<void> _delete(TransactionModel t) async {
    try {
      await widget.store.delete(t.id);
    } on DataException catch (e) {
      _showMessage(e.message);
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Deleted "${t.description}"'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 8),
          persist: false,
          action: SnackBarAction(label: 'Undo', onPressed: () => _undo(t)),
        ),
      );
  }

  /// Puts a deleted transaction back exactly as it was, under its own id
  /// (so an SMS one keeps its transaction code).
  Future<void> _undo(TransactionModel t) async {
    try {
      await widget.store.restore(t);
    } on DataException catch (e) {
      _showMessage(e.message);
      return;
    }
    _showMessage('Restored "${t.description}"');
  }

  /// Needs review › Account: saves [after] (only its account differs from
  /// [before]) and offers Undo, which puts [before] back exactly.
  Future<void> _assignAccount(
      TransactionModel before, TransactionModel after) async {
    try {
      await widget.store.update(after);
    } on DataException catch (e) {
      _showMessage(e.message);
      return;
    }
    if (!mounted) return;
    final name = widget.accounts.byId(after.accountId)?.name ?? 'the account';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('"${after.description}" is now on $name'),
      behavior: SnackBarBehavior.floating,
      persist: false,
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () async {
          try {
            await widget.store.update(before);
          } on DataException catch (e) {
            _showMessage(e.message);
          }
        },
      ),
    ));
  }

  void _openNeedsReview() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => NeedsReviewScreen(
        store: widget.store,
        onCorrect: _correctCategory,
        accounts: widget.accounts,
        onAssign: _assignAccount,
        onEdit: _openTransactionForm,
        simBackfill: widget.simBackfill,
      ),
    ));
  }

  /// When the user changes the category of a detected transaction, remember
  /// it for that merchant (used for new SMS from now on), and offer to use
  /// it for the merchant's other transactions. Nothing older changes unless
  /// the user confirms.
  Future<void> _learnFrom(TransactionModel before, TransactionModel after) async {
    if (!after.isDetected ||
        after.type != before.type ||
        !CategoryRule.learnable(after.type) ||
        after.categoryId == before.categoryId ||
        after.categoryId.startsWith('uncategorized')) {
      return;
    }
    final key = CategoryRule.keyForStored(after);
    if (key == null) return;
    final category = DefaultCategories.byId(after.categoryId).name;
    final merchant = before.description;
    try {
      await widget.categoryRules.remember(CategoryRule(
        key: key,
        categoryId: after.categoryId,
        type: after.type,
        label: merchant,
      ));
    } on DataException catch (e) {
      _showMessage(e.message);
      return;
    }

    // Others from the same merchant that are still uncategorized, or in the
    // category this one had before (most likely the same mistake).
    final others = widget.store.transactions
        .where((x) =>
            x.id != after.id &&
            x.isDetected &&
            x.type == after.type &&
            (x.categoryId.startsWith('uncategorized') ||
                x.categoryId == before.categoryId) &&
            CategoryRule.keyForStored(x) == key)
        .toList();
    if (!mounted) return;
    if (others.isEmpty) {
      _showMessage('New transactions from $merchant will be $category.');
      return;
    }
    final apply = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Use $category for ${others.length} more?'),
        content: Text(
          '${others.length} other ${others.length == 1 ? 'transaction' : 'transactions'} '
          'from $merchant ${others.length == 1 ? 'is' : 'are'} '
          '${DefaultCategories.byId(before.categoryId).name}. Only '
          '${others.length == 1 ? 'it' : 'those'} will change, and you can '
          'still edit each one later.\n\nNew transactions from $merchant '
          'will be $category either way.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Apply to ${others.length}'),
          ),
        ],
      ),
    );
    if (apply != true || !mounted) return;
    var changed = 0;
    try {
      for (final x in others) {
        await widget.store.update(x.withCategory(after.categoryId));
        changed++;
      }
    } on DataException catch (e) {
      _showMessage('Updated $changed of ${others.length}. ${e.message}');
      return;
    }
    _showMessage('Updated $changed transactions to $category.');
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  Future<void> _confirmSignOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        content: _SignedInAs(
          user: widget.user,
          photo: widget.avatar?.photo,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await widget.onSignOut();
    } on AuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      DashboardScreen(
        store: widget.store,
        onSeeAll: () => setState(() => _currentIndex = 1),
        onSignOut: _confirmSignOut,
        onOpenSettings: _openSettings,
        onOpenMenu: _openMenu,
        onTransactionTap: _openTransactionForm,
        onTransactionLongPress: _showActions,
        smsService: widget.smsService,
        accounts: widget.accounts,
        onManageAccounts: _openAccounts,
        onSetBalances: _setBalances,
        budgetRepository: widget.budgetRepository,
        categoryBudgets: widget.categoryBudgets,
        month: _month,
        onOpenBudgets: () => setState(() => _currentIndex = 2),
        onOpenTrends: _openTrends,
        user: widget.user,
        avatar: widget.avatar,
      ),
      TransactionsScreen(
        store: widget.store,
        onTransactionTap: _openTransactionForm,
        onTransactionLongPress: _showActions,
        onOpenMenu: _openMenu,
        onOpenNeedsReview: _openNeedsReview,
      ),
      BudgetsScreen(
        store: widget.store,
        budgetRepository: widget.budgetRepository,
        onOpenMenu: _openMenu,
        month: _month,
        categoryBudgets: widget.categoryBudgets,
        onOpenTrends: _openTrends,
      ),
    ];

    return Scaffold(
      key: _scaffoldKey,
      drawer: AppDrawer(
        user: widget.user,
        currentTab: _currentIndex,
        smsService: widget.smsService,
        onSelectTab: (index) => setState(() => _currentIndex = index),
        onOpenSettings: _openSettings,
        onSignOut: _confirmSignOut,
        avatar: widget.avatar,
      ),
      // IndexedStack keeps each tab's state (scroll position, filter).
      body: widget.categories == null
          ? IndexedStack(index: _currentIndex, children: pages)
          : ListenableBuilder(
              listenable: widget.categories!,
              builder: (context, _) =>
                  IndexedStack(index: _currentIndex, children: pages),
            ),
      floatingActionButton: _currentIndex == 2
          ? null
          : FloatingActionButton.extended(
              onPressed: _openTransactionForm,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add'),
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) =>
            setState(() => _currentIndex = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            selectedIcon: Icon(Icons.receipt_long_rounded),
            label: 'Transactions',
          ),
          NavigationDestination(
            icon: Icon(Icons.savings_outlined),
            selectedIcon: Icon(Icons.savings_rounded),
            label: 'Budgets',
          ),
        ],
      ),
    );
  }
}

/// Who is signed in: Google profile picture (or an initial) plus name/email.
class _SignedInAs extends StatelessWidget {
  const _SignedInAs({required this.user, this.photo});

  final AppUser user;
  final Uint8List? photo;

  @override
  Widget build(BuildContext context) {
    final name = user.displayName?.trim() ?? '';

    return Row(
      children: [
        UserAvatar(user: user, customImage: photo),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (name.isNotEmpty)
                Text(
                  name,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: context.colors.textPrimary,
                  ),
                ),
              Text(
                user.email,
                style: TextStyle(color: context.colors.textSecondary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

enum _RowAction { edit, delete }
