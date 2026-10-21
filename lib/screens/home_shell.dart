import 'dart:async';

import 'package:flutter/material.dart';

import '../data/budget_repository.dart';
import '../data/data_exception.dart';
import '../data/transaction_store.dart';
import '../models/transaction_model.dart';
import '../services/auth_service.dart';
import '../sms/sms_import_service.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';
import '../widgets/app_drawer.dart';
import '../widgets/user_avatar.dart';
import 'add_transaction_screen.dart';
import 'budgets_screen.dart';
import 'dashboard_screen.dart';
import 'settings_screen.dart';
import 'transactions_screen.dart';

/// The main app frame: bottom navigation bar, the current tab, and the
/// "Add" button that opens [AddTransactionScreen]. It also performs the
/// writes the form asks for (add / update / delete).
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.store,
    required this.budgetRepository,
    required this.smsService,
    required this.user,
    required this.onSignOut,
  });

  final TransactionStore store;
  final BudgetRepository budgetRepository;

  /// Automatic transaction detection (Android only; idle elsewhere).
  final SmsImportService smsService;
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

  @override
  void initState() {
    super.initState();
    _detectedSub = widget.smsService.detected.listen(_showDetected);
  }

  @override
  void dispose() {
    _detectedSub?.cancel();
    super.dispose();
  }

  /// In-app notification for a transaction found in an SMS, e.g.
  /// "New M-Pesa transaction detected: KSh 500.00 — Naivas", with a button
  /// to open it in the edit form (to fix the category, for example).
  void _showDetected(TransactionModel t) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('New ${t.source.label} transaction detected: '
              '${Formatters.currency(t.amount)} — ${t.description}'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: 'Edit',
            onPressed: () => _openTransactionForm(_latest(t)),
          ),
        ),
      );
  }

  /// The current version of [t] from the store, in case it changed since
  /// the notification appeared.
  TransactionModel _latest(TransactionModel t) => widget.store.transactions
      .firstWhere((x) => x.id == t.id, orElse: () => t);

  void _openSettings() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SettingsScreen(smsService: widget.smsService),
    ));
  }

  /// Opens the form to add a transaction, or to edit [existing].
  Future<void> _openTransactionForm([TransactionModel? existing]) async {
    final result = await Navigator.of(context).push<TransactionFormResult>(
      MaterialPageRoute(
        builder: (_) => AddTransactionScreen(initial: existing),
      ),
    );
    if (result == null || !mounted) return;

    final t = result.transaction;
    final store = widget.store;
    final (Future<void> write, String done) = switch (result) {
      TransactionSaved() when existing == null =>
        (store.add(t), 'Added "${t.description}"'),
      TransactionSaved() => (store.update(t), 'Saved changes'),
      TransactionDeleted() => (store.delete(t.id), 'Deleted "${t.description}"'),
    };

    // The list updates straight away from Firestore's local cache, so confirm
    // now; if the server later rejects the write, show why.
    _showMessage(done);
    try {
      await write;
    } on DataException catch (e) {
      _showMessage(e.message);
    }
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
        content: _SignedInAs(user: widget.user),
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
      ),
      TransactionsScreen(
        store: widget.store,
        onTransactionTap: _openTransactionForm,
        onOpenMenu: _openMenu,
      ),
      BudgetsScreen(
        store: widget.store,
        budgetRepository: widget.budgetRepository,
        onOpenMenu: _openMenu,
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
      ),
      // IndexedStack keeps each tab's state (scroll position, filter).
      body: IndexedStack(index: _currentIndex, children: pages),
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
  const _SignedInAs({required this.user});

  final AppUser user;

  @override
  Widget build(BuildContext context) {
    final name = user.displayName?.trim() ?? '';

    return Row(
      children: [
        UserAvatar(user: user),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (name.isNotEmpty)
                Text(
                  name,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
              Text(
                user.email,
                style: const TextStyle(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
