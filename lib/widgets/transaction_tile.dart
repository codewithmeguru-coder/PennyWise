import 'package:flutter/material.dart';

import '../models/transaction_category.dart';
import '../models/transaction_model.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';

/// One row in a transaction list: category icon, title, date and amount.
class TransactionTile extends StatelessWidget {
  const TransactionTile({super.key, required this.transaction, this.onTap});

  final TransactionModel transaction;

  /// Called when the row is tapped (opens the edit form).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = transaction;
    final category = DefaultCategories.byId(t.categoryId);
    final (color, sign) = switch (t.type) {
      TransactionType.income || TransactionType.refund => (AppColors.income, '+'),
      TransactionType.expense ||
      TransactionType.debtRepayment =>
        (AppColors.expense, '-'),
      // Moves between your own money: no sign, it wasn't earned or spent.
      TransactionType.transfer => (AppColors.neutral, ''),
      TransactionType.savingsContribution ||
      TransactionType.savingsWithdrawal =>
        (AppColors.savings, ''),
    };
    final accounts = switch (t.type) {
      TransactionType.transfer when t.effectiveAccount != null &&
              t.toAccount != null =>
        '${t.effectiveAccount!.label} → ${t.toAccount!.label}',
      _ => t.effectiveAccount?.label,
    };

    return ListTile(
      onTap: onTap,
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
        style: const TextStyle(
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
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
        ].join(' · '),
        style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
      ),
      trailing: Text(
        '$sign${Formatters.currency(t.amount)}',
        style: TextStyle(color: color, fontWeight: FontWeight.w700),
      ),
    );
  }
}
