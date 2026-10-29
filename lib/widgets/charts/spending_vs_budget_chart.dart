import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../utils/formatters.dart';
import 'chart_style.dart';

/// Spending through the month (one point per day so far) against the
/// month's budget, drawn as a flat dashed line. Without a budget only the
/// spending line is drawn.
class SpendingVsBudgetChart extends StatelessWidget {
  const SpendingVsBudgetChart({
    super.key,
    required this.cumulative,
    required this.daysInMonth,
    this.budget,
  });

  /// Spending up to the end of day 1, 2, … (see
  /// `SpendingTrend.cumulativeByDay`).
  final List<double> cumulative;
  final int daysInMonth;
  final double? budget;

  @override
  Widget build(BuildContext context) {
    final top = [
      ...cumulative,
      budget ?? 0,
    ].fold<double>(0, (m, v) => v > m ? v : m);
    final step = ChartStyle.interval(top);
    final spent = cumulative.isEmpty ? 0.0 : cumulative.last;
    final over = budget != null && spent > budget!;
    final lineColor = over ? context.colors.expense : context.colors.primary;
    return Semantics(
      label:
          'Spent ${Formatters.currency(spent)} so far'
          '${budget == null ? '' : ' of a ${Formatters.currency(budget!)} budget'}',
      excludeSemantics: true,
      child: Column(
        children: [
          SizedBox(
            height: ChartStyle.height,
            child: LineChart(
              LineChartData(
                minX: 1,
                maxX: daysInMonth.toDouble(),
                minY: 0,
                maxY: top <= 0 ? 1 : (top / step).ceil() * step,
                gridData: ChartStyle.grid(context),
                borderData: ChartStyle.border,
                lineTouchData: LineTouchData(
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipColor: (_) => context.colors.textPrimary,
                    getTooltipItems: (spots) => [
                      for (final s in spots)
                        LineTooltipItem(
                          'Day ${s.x.toInt()}\n${Formatters.currency(s.y)}',
                          TextStyle(
                            color: context.colors.surface,
                            fontSize: 12,
                          ),
                        ),
                    ],
                  ),
                ),
                extraLinesData: ExtraLinesData(
                  horizontalLines: [
                    if (budget != null)
                      HorizontalLine(
                        y: budget!,
                        color: context.colors.warning,
                        strokeWidth: 2,
                        dashArray: [6, 4],
                      ),
                  ],
                ),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(),
                  rightTitles: const AxisTitles(),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 36,
                      interval: step,
                      getTitlesWidget: (value, meta) => SideTitleWidget(
                        meta: meta,
                        child: Text(
                          ChartStyle.compact(value),
                          style: ChartStyle.axisLabel(context),
                        ),
                      ),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 24,
                      interval: 7,
                      getTitlesWidget: (value, meta) => SideTitleWidget(
                        meta: meta,
                        child: Text(
                          '${value.toInt()}',
                          style: ChartStyle.axisLabel(context),
                        ),
                      ),
                    ),
                  ),
                ),
                lineBarsData: [
                  if (cumulative.isNotEmpty)
                    LineChartBarData(
                      spots: [
                        for (var i = 0; i < cumulative.length; i++)
                          FlSpot(i + 1.0, cumulative[i]),
                      ],
                      color: lineColor,
                      barWidth: 3,
                      isCurved: false,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(
                        show: true,
                        color: lineColor.withValues(alpha: 0.12),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 16,
            children: [
              _Key(color: lineColor, label: 'Spent'),
              if (budget != null)
                _Key(color: context.colors.warning, label: 'Budget'),
            ],
          ),
        ],
      ),
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 14, height: 3, color: color),
        const SizedBox(width: 6),
        Text(label, style: ChartStyle.axisLabel(context)),
      ],
    );
  }
}
