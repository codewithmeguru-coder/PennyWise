import 'package:flutter/material.dart';

import '../data/transaction_store.dart';
import '../accounts/account_balances.dart';
import '../accounts/account_repository.dart';
import '../sms/sms_import_service.dart';
import '../widgets/account_cards.dart';
import '../models/transaction_model.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';
import '../widgets/balance_card.dart';
import '../widgets/empty_state.dart';
import '../widgets/section_header.dart';
import '../widgets/transaction_tile.dart';

/// Home tab: balance overview plus the most recent transactions.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({
    super.key,
    required this.store,
    required this.onSeeAll,
    required this.onSignOut,
    required this.onTransactionTap,
    this.onOpenSettings,
    this.onOpenMenu,
    this.smsService,
    this.accounts,
    this.onManageAccounts,
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

  /// Called when the user taps a transaction (opens the edit form).
  final ValueChanged<TransactionModel> onTransactionTap;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final recent = store.recent();

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
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('PennyWise'),
                  Text(
                    Formatters.monthYear(DateTime.now()),
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
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
                              onSetUp: acc.createStarterSet,
                            )
                          : const SizedBox.shrink(),
                    ),
                  // After "Start balances over", the balance and savings come
                  // from the account cards rather than the whole history.
                  ListenableBuilder(
                    listenable: Listenable.merge([accounts]),
                    builder: (context, _) {
                      final totals = accounts == null
                          ? null
                          : AccountBalance.totals(
                              accounts!.active, store.transactions);
                      return BalanceCard(
                        balance: totals?.available ?? store.balance,
                        savings: totals?.savings ?? store.savingsBalance,
                        monthIncome: store.monthIncome,
                        monthExpenses: store.monthExpenses,
                      );
                    },
                  ),
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
                            onTap: () => onTransactionTap(recent[i]),
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
      color: AppColors.warning.withValues(alpha: 0.10),
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: const Icon(Icons.sms_failed_outlined, color: AppColors.warning),
        title: Text('SMS detection last ran '
            '${Formatters.relativeDate(lastScan).toLowerCase()}'),
        subtitle: const Text('PennyWise checks your messages only while it is '
            'open. Open Settings to check now or import the last 30 days.'),
        onTap: onOpenSettings,
      ),
    );
  }
}
