import 'package:flutter/material.dart';

import '../data/transaction_store.dart';
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
                  BalanceCard(
                    balance: store.balance,
                    savings: store.savingsBalance,
                    monthIncome: store.monthIncome,
                    monthExpenses: store.monthExpenses,
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
