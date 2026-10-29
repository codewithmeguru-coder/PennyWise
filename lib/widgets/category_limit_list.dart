import 'package:flutter/material.dart';

import '../models/category_budget.dart';
import '../models/monthly_summary.dart';
import '../models/transaction_category.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';

/// The month's spending per category, each against its limit when it has
/// one (see [CategoryBudgetSummary]).
///
/// Every row states the amount and its share of the month's spending, as
/// the category chart always did. A category with a limit gets a meter in
/// its status colour and what's left (or over); one without gets a bar
/// relative to the largest spend and, when a limit can be set, "Set limit".
class CategoryLimitList extends StatelessWidget {
  const CategoryLimitList({super.key, required this.rows, this.onEdit});

  /// Over-limit first, then near-limit, then by amount (see
  /// [CategoryBudgetSummary.rows]). Must not be empty.
  final List<CategoryLimitStatus> rows;

  /// Opens the limit dialog for a category. Null: limits can't be changed
  /// (e.g. they couldn't be loaded).
  final ValueChanged<String>? onEdit;

  @override
  Widget build(BuildContext context) {
    final largest = rows.fold<double>(0, (m, r) => r.spent > m ? r.spent : m);
    return Column(
      children: [
        for (final row in rows)
          _LimitRow(
            row: row,
            fraction: largest <= 0 ? 0 : row.spent / largest,
            // A turned-off category keeps (and can change) its limit, but
            // isn't offered a new one.
            onEdit: onEdit != null &&
                    CategoryBudget.canHaveLimit(row.categoryId) &&
                    (row.hasLimit ||
                        !DefaultCategories.isInactive(row.categoryId))
                ? () => onEdit!(row.categoryId)
                : null,
          ),
      ],
    );
  }
}

class _LimitRow extends StatelessWidget {
  const _LimitRow({required this.row, required this.fraction, this.onEdit});

  final CategoryLimitStatus row;

  /// Bar length for a row without a limit, 0–1 of the width.
  final double fraction;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final category = DefaultCategories.byId(row.categoryId);
    final amount = Formatters.currency(row.spent);
    final percent = '${(row.share * 100).round()}%';
    final status = row.status;
    final color = switch (status) {
      BudgetStatus.over => AppColors.expense,
      BudgetStatus.nearLimit => AppColors.warning,
      _ => AppColors.primary,
    };

    final String? limitText;
    if (row.hasLimit) {
      final limit = Formatters.currency(row.limit!);
      final remaining = row.remaining!;
      limitText = status == BudgetStatus.over
          ? '${Formatters.currency(-remaining)} over the $limit limit'
          : '${Formatters.currency(remaining)} left of $limit'
                '${status == BudgetStatus.nearLimit ? ' · near limit' : ''}';
    } else {
      limitText = null;
    }

    return Semantics(
      label:
          '${category.name}: $amount, $percent of spending'
          '${limitText == null ? '' : ', $limitText'}',
      excludeSemantics: true,
      button: onEdit != null,
      child: InkWell(
        onTap: onEdit,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: color.withValues(alpha: 0.1),
                child: Icon(category.icon, size: 18, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            category.name,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                        Text(
                          amount,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        SizedBox(
                          width: 48,
                          child: Text(
                            percent,
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    if (row.hasLimit) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: row.usedFraction!.clamp(0.0, 1.0),
                          minHeight: 8,
                          color: color,
                          backgroundColor: color.withValues(alpha: 0.15),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        limitText!,
                        style: TextStyle(
                          fontSize: 12,
                          color: status == BudgetStatus.over
                              ? AppColors.expense
                              : AppColors.textSecondary,
                        ),
                      ),
                    ] else
                      Row(
                        children: [
                          Expanded(
                            child: FractionallySizedBox(
                              widthFactor: fraction.clamp(0.02, 1.0),
                              alignment: Alignment.centerLeft,
                              child: Container(
                                height: 10,
                                decoration: const BoxDecoration(
                                  color: AppColors.primary,
                                  borderRadius: BorderRadius.horizontal(
                                    right: Radius.circular(4),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          if (onEdit != null) ...[
                            const SizedBox(width: 8),
                            const Text(
                              'Set limit',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: AppColors.primary,
                              ),
                            ),
                          ],
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
