import 'package:flutter/material.dart';

import '../models/monthly_summary.dart';
import '../models/transaction_category.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';

/// Horizontal bar chart of a month's spending per category, largest first.
///
/// Bar length is relative to the largest category, so the biggest spend is a
/// full-width bar and the rest compare against it. Each row also states the
/// amount and its share of total expenses, so the chart doubles as a table.
class CategorySpendChart extends StatelessWidget {
  const CategorySpendChart({super.key, required this.categories});

  /// Must be sorted largest first and non-empty (see [MonthlySummary]).
  final List<CategorySpend> categories;

  @override
  Widget build(BuildContext context) {
    final largest = categories.first.amount;

    return Column(
      children: [
        for (final item in categories)
          _CategoryBar(item: item, fraction: item.amount / largest),
      ],
    );
  }
}

class _CategoryBar extends StatelessWidget {
  const _CategoryBar({required this.item, required this.fraction});

  final CategorySpend item;

  /// Bar length, 0–1 of the available width.
  final double fraction;

  @override
  Widget build(BuildContext context) {
    final category = DefaultCategories.byId(item.categoryId);
    final amount = Formatters.currency(item.amount);
    final percent = '${(item.share * 100).round()}%';

    return Semantics(
      label: '${category.name}: $amount, $percent of spending',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: AppColors.primary.withValues(alpha: 0.1),
              child: Icon(category.icon, size: 18, color: AppColors.primary),
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
                  // Grows from the left baseline: square there, 4px rounded
                  // at the data end. Kept thin (10px).
                  FractionallySizedBox(
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
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
