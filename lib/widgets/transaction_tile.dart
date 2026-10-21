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
    final category = DefaultCategories.byId(transaction.categoryId);
    final color =
        transaction.isExpense ? AppColors.expense : AppColors.income;
    final sign = transaction.isExpense ? '-' : '+';

    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: color.withValues(alpha: 0.12),
        child: Icon(category.icon, color: color, size: 22),
      ),
      title: Text(
        transaction.description,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
        ),
      ),
      subtitle: Text(
        [
          category.name,
          Formatters.relativeDate(transaction.date),
          // e.g. "M-Pesa", so detected transactions are easy to spot.
          if (transaction.isDetected) transaction.source.label,
        ].join(' · '),
        style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
      ),
      trailing: Text(
        '$sign${Formatters.currency(transaction.amount)}',
        style: TextStyle(color: color, fontWeight: FontWeight.w700),
      ),
    );
  }
}
