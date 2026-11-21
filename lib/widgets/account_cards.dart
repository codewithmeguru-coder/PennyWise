import 'package:flutter/material.dart';

import '../accounts/account_balances.dart';
import '../accounts/loan_limit.dart';
import '../accounts/money_account.dart';
import '../models/transaction_model.dart';
import '../privacy/savings_privacy.dart';
import '../theme/app_theme.dart';

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
    this.onSetBalances,
  });

  final List<MoneyAccount> accounts;
  final List<TransactionModel> transactions;
  final VoidCallback onManage;

  /// Creates the suggested starter accounts; shown when there are none.
  final VoidCallback? onSetUp;

  /// Opens "Set starting balances"; offered while any account has none.
  final VoidCallback? onSetBalances;

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
              Row(
                children: [
                  Icon(Icons.account_balance_wallet_outlined,
                      color: context.colors.primary),
                  SizedBox(width: 8),
                  Text('Set up your accounts',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'SIM 1 and SIM 2 M-Pesa, each with its own Ziidi and Fuliza, '
                'and Cash. Add banks yourself.',
                style: TextStyle(color: context.colors.textSecondary),
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
          if (onSetBalances != null && balances.any((b) => !b.hasOpening))
            _ManageCard(
              onTap: onSetBalances!,
              icon: Icons.flag_outlined,
              label: 'Set balances',
            ),
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
    // A loan shows what is owed (positive), never as money available.
    final amount = isLoan ? b.owed : b.shown;
    final masked = b.account.kind == AccountKind.savings &&
        SavingsPrivacy.hidden(context);
    final limit = LoanLimit.of(b);
    final limitWarning = limit != null && limit.level != LoanLimitLevel.ok;
    final status = limit != null
        ? '${SavingsPrivacy.money(context, limit.available)} left of '
            '${SavingsPrivacy.money(context, limit.limit)}'
        : isLoan
        ? (amount > 0
            ? (b.shownFromSms ? 'Owed · from latest SMS' : 'Owed')
            : amount < 0
                ? 'Credit? Check the amount owed'
                : (b.hasOpening || b.shownFromSms
                    ? 'Nothing owed'
                    : 'Owed: not set'))
        : switch (b.status) {
            BalanceStatus.verified => 'Matches latest SMS',
            BalanceStatus.mismatch => masked
                ? 'SMS differs'
                : 'SMS differs by ${SavingsPrivacy.money(context, b.difference!.abs())}',
            BalanceStatus.anchored => 'From starting balance',
            BalanceStatus.fromSms => 'From latest SMS',
            BalanceStatus.unverified => 'Estimated · no starting balance',
          };
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
                    Icon(_icon, size: 18, color: context.colors.primary),
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
                    masked
                        ? SavingsPrivacyController.mask
                        : '${b.isEstimate && !isLoan ? '~' : ''}'
                              '${SavingsPrivacy.money(context, amount)}',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: isLoan && amount > 0
                          ? context.colors.expense
                          : context.colors.textPrimary,
                    ),
                  ),
                ),
                if (limit != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: limit.usedShare.clamp(0.0, 1.0),
                      minHeight: 4,
                      color: limitWarning
                          ? context.colors.warning
                          : context.colors.primary,
                    ),
                  ),
                Text(
                  status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: limitWarning ? FontWeight.w600 : null,
                    color: b.differs || (isLoan && amount < 0) || limitWarning
                        ? context.colors.warning
                        : context.colors.textSecondary,
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
        color: context.colors.warning.withValues(alpha: 0.08),
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
              Text(
                'M-Pesa transactions',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: context.colors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ManageCard extends StatelessWidget {
  const _ManageCard({
    required this.onTap,
    this.icon = Icons.tune_rounded,
    this.label = 'Accounts',
  });

  final VoidCallback onTap;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 96,
      child: Card(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: context.colors.primary),
              const SizedBox(height: 6),
              Text(label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}
