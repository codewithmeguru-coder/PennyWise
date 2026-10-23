import 'package:flutter/material.dart';

import '../accounts/account_balances.dart';
import '../accounts/money_account.dart';
import '../models/transaction_model.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';

/// A row of account cards for the top of the Home screen: one per active
/// account (SIM 1 M-Pesa, SIM 2 M-Pesa, Ziidi, Fuliza, Equity, Cash...),
/// plus a card for transactions not linked to any account yet.
class AccountCards extends StatelessWidget {
  const AccountCards({
    super.key,
    required this.accounts,
    required this.transactions,
    required this.onManage,
    this.onSetUp,
  });

  final List<MoneyAccount> accounts;
  final List<TransactionModel> transactions;
  final VoidCallback onManage;

  /// Creates the suggested starter accounts; shown when there are none.
  final VoidCallback? onSetUp;

  @override
  Widget build(BuildContext context) {
    if (accounts.isEmpty) {
      return Card(
        margin: const EdgeInsets.only(bottom: 16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.account_balance_wallet_outlined,
                      color: AppColors.primary),
                  SizedBox(width: 8),
                  Text('Set up your accounts',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'SIM 1 and SIM 2 M-Pesa, each with its own Ziidi and Fuliza, '
                'and Cash. Add banks yourself.',
                style: TextStyle(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: onSetUp,
                  child: const Text('Set up accounts'),
                ),
              ),
            ],
          ),
        ),
      );
    }
    final balances = AccountBalance.forAll(accounts, transactions);
    final unassigned = transactions
        .where((t) => t.accountId == null && t.effectiveAccount == Account.mpesa)
        .length;
    return SizedBox(
      height: 132,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(bottom: 12),
        children: [
          for (final b in balances) _AccountCard(balance: b, onTap: onManage),
          if (unassigned > 0) _UnassignedCard(count: unassigned),
          _ManageCard(onTap: onManage),
        ],
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.balance, required this.onTap});

  final AccountBalance balance;
  final VoidCallback onTap;

  IconData get _icon => switch (balance.account.kind) {
        AccountKind.mobileMoney => Icons.phone_android_rounded,
        AccountKind.bank => Icons.account_balance_rounded,
        AccountKind.cash => Icons.payments_outlined,
        AccountKind.savings => Icons.savings_rounded,
        AccountKind.loan => Icons.credit_score_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final b = balance;
    final isLoan = b.account.kind == AccountKind.loan;
    final amount = isLoan ? -b.shown : b.shown;
    final String status;
    if (b.reported != null) {
      status = 'From latest SMS';
    } else if (isLoan) {
      status = amount > 0 ? 'Owed' : 'Nothing owed';
    } else if (b.isEstimate) {
      status = 'Estimated · no starting balance';
    } else {
      status = 'Calculated';
    }
    return SizedBox(
      width: 172,
      child: Card(
        margin: const EdgeInsets.only(right: 10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(_icon, size: 18, color: AppColors.primary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        b.account.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${b.isEstimate && b.reported == null && !isLoan ? '~' : ''}'
                    '${Formatters.currency(amount)}',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: isLoan && amount > 0
                          ? AppColors.expense
                          : AppColors.textPrimary,
                    ),
                  ),
                ),
                Text(
                  b.differs ? 'Differs from PennyWise records' : status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: b.differs
                        ? AppColors.warning
                        : AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _UnassignedCard extends StatelessWidget {
  const _UnassignedCard({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 172,
      child: Card(
        margin: const EdgeInsets.only(right: 10),
        color: AppColors.warning.withValues(alpha: 0.08),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            // One line each, like the account cards, so large phone text
            // can't push the card past its fixed height.
            children: [
              const Text(
                'SIM not recorded',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  '$count',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              const Text(
                'M-Pesa transactions',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ManageCard extends StatelessWidget {
  const _ManageCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 96,
      child: Card(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: const Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.tune_rounded, color: AppColors.primary),
              SizedBox(height: 6),
              Text('Accounts', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}
