import 'package:flutter/material.dart';

import '../data/budget_repository.dart';
import '../data/category_budget_repository.dart';
import '../data/transaction_store.dart';
import '../models/fuliza_link.dart';
import '../models/month_selection.dart';
import '../accounts/account_balances.dart';
import '../accounts/account_repository.dart';
import '../sms/sms_import_service.dart';
import '../widgets/account_cards.dart';
import '../models/transaction_model.dart';
import '../services/auth_service.dart';
import '../services/avatar_store.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';
import '../widgets/balance_card.dart';
import '../widgets/empty_state.dart';
import '../widgets/monthly_overview_card.dart';
import '../widgets/section_header.dart';
import '../widgets/transaction_tile.dart';
import '../widgets/welcome_greeting.dart';

/// Home tab: balances, the monthly overview, and the most recent
/// transactions.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({
    super.key,
    required this.store,
    required this.onSeeAll,
    required this.onSignOut,
    required this.onTransactionTap,
    this.onTransactionLongPress,
    this.onOpenSettings,
    this.onOpenMenu,
    this.smsService,
    this.accounts,
    this.onManageAccounts,
    this.onSetBalances,
    this.budgetRepository,
    this.categoryBudgets,
    this.month,
    this.onOpenBudgets,
    this.onOpenTrends,
    this.user,
    this.avatar,
  });

  final TransactionStore store;

  /// Called when the user taps "See all" (switches to the Transactions tab).
  final VoidCallback onSeeAll;

  /// Called when the user taps the sign-out button in the app bar.
  final VoidCallback onSignOut;

  /// Called when the user taps the settings button in the app bar.
  final VoidCallback? onOpenSettings;

  /// Opens the side menu. When null, no ☰ button is shown.
  final VoidCallback? onOpenMenu;

  /// When set, a notice appears if SMS detection hasn't run for days.
  final SmsImportService? smsService;

  /// The user's own accounts, shown as cards above the summary.
  final AccountStore? accounts;
  final VoidCallback? onManageAccounts;

  /// Opens "Set starting balances" (see [AccountCards.onSetBalances]).
  final VoidCallback? onSetBalances;

  /// With [month], shows the monthly overview (budgets come from here).
  final BudgetRepository? budgetRepository;

  /// Category limits, for the overview's "over its limit" line.
  final CategoryBudgetRepository? categoryBudgets;

  /// The month the overview shows, shared with Budgets.
  final MonthSelection? month;

  /// Switches to the Budgets tab.
  final VoidCallback? onOpenBudgets;

  /// Opens month-by-month Trends.
  final VoidCallback? onOpenTrends;

  /// Who is signed in: the header greets them by first name beside their
  /// photo. Without one, the header says PennyWise.
  final AppUser? user;

  /// [user]'s own uploaded photo.
  final AvatarStore? avatar;

  /// Called when the user taps a transaction (opens the edit form).
  final ValueChanged<TransactionModel> onTransactionTap;

  /// Opens the Edit / Delete menu for a transaction.
  final ValueChanged<TransactionModel>? onTransactionLongPress;

  static Widget _headerMonth(BuildContext context, DateTime month) => Text(
    Formatters.monthYear(month),
    key: const Key('home-header-month'),
    style: TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w500,
      color: context.colors.textSecondary,
    ),
  );

  /// The month the overview shows (shared with Budgets), so the header
  /// never names a different one.
  Widget _monthOnShow(BuildContext context) => switch (month) {
    final m? => ValueListenableBuilder<DateTime>(
      valueListenable: m,
      builder: (context, shown, _) => _headerMonth(context, shown),
    ),
    null => _headerMonth(context, DateTime.now()),
  };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final recent = store.recent();
        final links = FulizaLinks(store.transactions);

        return CustomScrollView(
          slivers: [
            SliverAppBar(
              pinned: true,
              toolbarHeight: 72,
              leading: onOpenMenu == null
                  ? null
                  : IconButton(
                      tooltip: 'Menu',
                      icon: const Icon(Icons.menu_rounded),
                      onPressed: onOpenMenu,
                    ),
              title: switch (user) {
                final u? => WelcomeGreeting(
                  user: u,
                  avatar: avatar,
                  subtitle: _monthOnShow(context),
                ),
                null => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [const Text('PennyWise'), _monthOnShow(context)],
                ),
              },
              actions: [
                if (onOpenSettings != null)
                  IconButton(
                    tooltip: 'Settings',
                    icon: const Icon(Icons.settings_outlined),
                    onPressed: onOpenSettings,
                  ),
                IconButton(
                  tooltip: 'Sign out',
                  icon: const Icon(Icons.logout_rounded),
                  onPressed: onSignOut,
                ),
                const SizedBox(width: 4),
              ],
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              sliver: SliverList.list(
                children: [
                  if (smsService case final sms?)
                    ListenableBuilder(
                      listenable: sms,
                      builder: (context, _) => sms.isStale
                          ? _StaleDetectionNotice(
                              lastScan: sms.lastScan!,
                              onOpenSettings: onOpenSettings,
                            )
                          : const SizedBox.shrink(),
                    ),
                  // Accounts first, the overall summary underneath.
                  if (accounts case final acc?)
                    ListenableBuilder(
                      listenable: acc,
                      builder: (context, _) => acc.isLoaded
                          ? AccountCards(
                              accounts: acc.active,
                              transactions: store.transactions,
                              onManage: onManageAccounts ?? () {},
                              onSetBalances: onSetBalances,
                              onSetUp: acc.createStarterSet,
                            )
                          : const SizedBox.shrink(),
                    ),
                  // With accounts, the balance and savings are the account
                  // cards' (anchored balances), labelled by how far they can
                  // be trusted. Without accounts there is nothing to anchor
                  // to: the figure is only the sum of recorded history.
                  ListenableBuilder(
                    listenable: Listenable.merge([accounts]),
                    builder: (context, _) {
                      final totals = accounts == null
                          ? null
                          : AccountBalance.totals(
                              accounts!.active, store.transactions);
                      final String? note;
                      if (totals == null) {
                        note = store.transactions.isEmpty
                            ? null
                            : 'Sum of recorded transactions only. Set up '
                                'accounts with starting balances for your '
                                'real balance.';
                      } else if (totals.unverified > 0) {
                        final u = totals.unverified;
                        note = '$u ${u == 1 ? 'account has' : 'accounts have'}'
                            ' no starting balance: estimated';
                      } else if (totals.mismatched > 0) {
                        final m = totals.mismatched;
                        note = '$m ${m == 1 ? 'account differs' : 'accounts differ'}'
                            ' from the latest SMS: check Accounts';
                      } else {
                        note = null;
                      }
                      return BalanceCard(
                        balance: totals?.available ?? store.balance,
                        savings: totals?.savings ?? store.savingsBalance,
                        note: note,
                        noteLabel: totals == null
                            ? 'Not a balance'
                            : totals.unverified > 0
                                ? 'Estimated'
                                : 'Check',
                      );
                    },
                  ),
                  if (budgetRepository != null && month != null) ...[
                    const SizedBox(height: 12),
                    MonthlyOverviewCard(
                      store: store,
                      budgetRepository: budgetRepository!,
                      categoryBudgets: categoryBudgets,
                      month: month!,
                      onOpenBudgets: onOpenBudgets,
                      onOpenTrends: onOpenTrends,
                    ),
                  ],
                  const SizedBox(height: 20),
                  SectionHeader(
                    title: 'Recent transactions',
                    actionLabel: 'See all',
                    onAction: onSeeAll,
                  ),
                ],
              ),
            ),
            if (store.isLoading)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (store.error != null)
              SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(
                  icon: Icons.cloud_off_rounded,
                  title: 'Couldn\'t load transactions',
                  message: store.error!,
                  actionLabel: 'Retry',
                  onAction: store.retry,
                ),
              )
            else if (recent.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(
                  icon: Icons.receipt_long_rounded,
                  title: 'No transactions yet',
                  message: 'Tap the + button to add your first one.',
                ),
              )
            else
              SliverPadding(
                // Bottom padding keeps the last row clear of the FAB.
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                sliver: SliverToBoxAdapter(
                  child: Card(
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        for (var i = 0; i < recent.length; i++) ...[
                          if (i > 0)
                            const Divider(height: 1, indent: 72),
                          TransactionTile(
                            transaction: recent[i],
                            paidWithFuliza: links.paidWithFuliza(recent[i]),
                            onTap: () => onTransactionTap(recent[i]),
                            onLongPress: onTransactionLongPress == null
                                ? null
                                : () => onTransactionLongPress!(recent[i]),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// "SMS detection hasn't run since …": detection only works while
/// PennyWise is open, so a long gap means messages may be waiting.
class _StaleDetectionNotice extends StatelessWidget {
  const _StaleDetectionNotice({required this.lastScan, this.onOpenSettings});

  final DateTime lastScan;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: context.colors.warning.withValues(alpha: 0.10),
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Icon(Icons.sms_failed_outlined, color: context.colors.warning),
        title: Text('SMS detection last ran '
            '${Formatters.relativeDate(lastScan).toLowerCase()}'),
        subtitle: const Text('PennyWise checks your messages only while it is '
            'open. Open Settings to check now or import the last 30 days.'),
        onTap: onOpenSettings,
      ),
    );
  }
}
