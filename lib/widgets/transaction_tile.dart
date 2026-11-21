import 'package:flutter/material.dart';

import '../models/ledger.dart';
import '../privacy/savings_privacy.dart';
import '../models/transaction_category.dart';
import '../models/transaction_model.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';

/// One row in a transaction list: category icon, title, date and amount.
class TransactionTile extends StatelessWidget {
  const TransactionTile({
    super.key,
    required this.transaction,
    this.onTap,
    this.onLongPress,
    this.paidWithFuliza = false,
  });

  final TransactionModel transaction;

  /// The payment was completed with a Fuliza loan (see `FulizaLinks`):
  /// says so, so it isn't mistaken for the loan itself.
  final bool paidWithFuliza;

  /// Called when the row is tapped (opens the edit form).
  final VoidCallback? onTap;

  /// Called on a long press (opens the Edit / Delete menu).
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final t = transaction;
    final category = DefaultCategories.byId(t.categoryId);
    final (color, sign) = switch (t.type) {
      TransactionType.income || TransactionType.refund => (context.colors.income, '+'),
      TransactionType.expense ||
      TransactionType.debtRepayment =>
        (context.colors.expense, '-'),
      // Moves between your own money: no sign, it wasn't earned or spent.
      TransactionType.transfer => (context.colors.neutral, ''),
      TransactionType.savingsContribution ||
      TransactionType.savingsWithdrawal =>
        (context.colors.savings, ''),
    };
    final accounts = switch (t.type) {
      // Borrowed (a Fuliza loan): from the loan, which has no generic account.
      TransactionType.transfer when t.account == null &&
              t.accountId != null &&
              t.toAccount != null =>
        'Fuliza → ${t.toAccount!.label}',
      TransactionType.transfer when t.effectiveAccount != null &&
              t.toAccount != null =>
        '${t.effectiveAccount!.label} → ${t.toAccount!.label}',
      _ => t.effectiveAccount?.label,
    };

    return ListTile(
      onTap: onTap,
      onLongPress: onLongPress,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: color.withValues(alpha: 0.12),
        child: Icon(category.icon, color: color, size: 22),
      ),
      title: Text(
        t.description,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: context.colors.textPrimary,
        ),
      ),
      subtitle: Text(
        [
          // Refunds and savings say what they are, not just the category.
          if (t.type == TransactionType.refund)
            'Refund · ${category.name}'
          else
            category.name,
          Formatters.relativeDate(t.date),
          // e.g. "M-Pesa", or "M-Pesa → Cash" for a cash withdrawal.
          ?accounts,
          if (paidWithFuliza) 'Paid with Fuliza loan',
        ].join(' · '),
        style: TextStyle(color: context.colors.textSecondary, fontSize: 13),
      ),
      trailing: _Amount(transaction: t, sign: sign, color: color),
    );
  }
}

/// The amount column. With a fee (e.g. the M-Pesa charge), spending shows
/// what left your account in total, and a transfer shows the amount moved
/// plus the fee on a second line, so the fee is visible but never added
/// twice.
class _Amount extends StatelessWidget {
  const _Amount({
    required this.transaction,
    required this.sign,
    required this.color,
  });

  final TransactionModel transaction;
  final String sign;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = transaction;
    final fee = t.fee ?? 0;
    final isSavings = t.type == TransactionType.savingsContribution ||
        t.type == TransactionType.savingsWithdrawal;
    if (isSavings && SavingsPrivacy.hidden(context)) {
      return _line(SavingsPrivacyController.mask);
    }
    if (fee <= 0) return _line('$sign${SavingsPrivacy.money(context, t.amount)}');

    // Expenses and debt repayments: the fee is part of what they cost.
    final spending = t.type == TransactionType.expense ||
        t.type == TransactionType.debtRepayment;
    final main = spending
        ? Ledger.fromCents(Ledger.toCents(t.amount) + Ledger.toCents(fee))
        : t.amount;
    final feeText = SavingsPrivacy.money(context, fee);
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        _line('$sign${SavingsPrivacy.money(context, main)}'),
        Text(
          spending ? 'incl. $feeText fee' : '+$feeText fee',
          style: TextStyle(color: context.colors.expense, fontSize: 12),
        ),
      ],
    );
  }

  Widget _line(String text) => Text(
        text,
        style: TextStyle(color: color, fontWeight: FontWeight.w700),
      );
}
