import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../models/monthly_summary.dart';
import '../../models/transaction_category.dart';
import '../../theme/app_theme.dart';
import '../../utils/formatters.dart';
import 'chart_style.dart';

/// One slice of a [CategoryDonut]: a category, or "Other" (null id).
class DonutSlice {
  const DonutSlice(this.categoryId, this.amount, this.share);

  /// Null for "Other", which groups the smaller categories.
  final String? categoryId;
  final double amount;

  /// Fraction (0–1) of the total.
  final double share;

  String get label =>
      categoryId == null ? 'Other' : DefaultCategories.byId(categoryId!).name;
}

/// The month's spending by category as a donut: the largest [maxSlices]
/// categories, then "Other" for the rest, with a legend of amounts.
///
/// Takes [MonthlySummary.byCategory] as it is, so the amounts and shares
/// are the ledger's (refunds already taken off their category).
class CategoryDonut extends StatelessWidget {
  const CategoryDonut({
    super.key,
    required this.categories,
    this.maxSlices = 5,
    this.onTap,
  });

  /// Largest first (see [MonthlySummary.byCategory]); may be empty.
  final List<CategorySpend> categories;
  final int maxSlices;

  /// Tapping the chart, e.g. to open the full list.
  final VoidCallback? onTap;

  /// The slices drawn: the largest [maxSlices] categories, then one
  /// "Other" holding everything else, so the slices add up to the total.
  static List<DonutSlice> slices(
    List<CategorySpend> categories, {
    int maxSlices = 5,
  }) {
    // A single leftover category is shown as itself, not as "Other".
    final keep = categories.length <= maxSlices + 1
        ? categories.length
        : maxSlices;
    return [
      for (final c in categories.take(keep))
        DonutSlice(c.categoryId, c.amount, c.share),
      if (categories.length > keep)
        DonutSlice(
          null,
          MonthlySummary.fromCents(
            categories
                .skip(keep)
                .fold(0, (sum, c) => sum + MonthlySummary.toCents(c.amount)),
          ),
          categories.skip(keep).fold(0.0, (sum, c) => sum + c.share),
        ),
    ];
  }

  static Color colorFor(BuildContext context, int index, DonutSlice slice) => slice.categoryId == null
      ? context.colors.textSecondary
      : ChartStyle.series(context, index);

  @override
  Widget build(BuildContext context) {
    final parts = slices(categories, maxSlices: maxSlices);
    final total = parts.fold(0.0, (sum, s) => sum + s.amount);
    return Semantics(
      label:
          'Spending by category: ${[for (final s in parts) '${s.label} ${Formatters.currency(s.amount)}'].join(', ')}',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        // Side by side when there's room; on a narrow screen or with large
        // text, the legend goes under the chart.
        child: LayoutBuilder(
          builder: (context, constraints) {
            final donut = _donut(context, parts, total);
            final legend = _legend(context, parts);
            if (constraints.maxWidth < 360) {
              return Column(
                children: [donut, const SizedBox(height: 12), legend],
              );
            }
            return Row(
              children: [
                donut,
                const SizedBox(width: 16),
                Expanded(child: legend),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _donut(BuildContext context, List<DonutSlice> parts, double total) => SizedBox(
    width: 120,
    height: 120,
    child: Stack(
      alignment: Alignment.center,
      children: [
        PieChart(
          PieChartData(
            sectionsSpace: 2,
            centerSpaceRadius: 36,
            startDegreeOffset: -90,
            pieTouchData: PieTouchData(enabled: false),
            sections: [
              for (var i = 0; i < parts.length; i++)
                PieChartSectionData(
                  value: parts[i].amount,
                  color: colorFor(context, i, parts[i]),
                  radius: 20,
                  showTitle: false,
                ),
            ],
          ),
        ),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              ChartStyle.compact(total),
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: context.colors.textPrimary,
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _legend(BuildContext context, List<DonutSlice> parts) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (var i = 0; i < parts.length; i++)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: colorFor(context, i, parts[i]),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  parts[i].label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                Formatters.currency(parts[i].amount),
                style: TextStyle(
                  fontSize: 12,
                  color: context.colors.textSecondary,
                ),
              ),
            ],
          ),
        ),
    ],
  );
}
