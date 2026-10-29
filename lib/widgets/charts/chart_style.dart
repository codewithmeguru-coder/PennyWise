import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../utils/formatters.dart';

/// Shared look for every PennyWise chart (Fuliza report now; Home charts,
/// monthly trends and Insights later), so they read as one set.
class ChartStyle {
  ChartStyle._();

  /// Series colours in order. SIM 1 and SIM 2 always get the first two.
  static const List<Color> palette = [
    AppColors.primary,
    AppColors.savings,
    AppColors.warning,
    AppColors.neutral,
    AppColors.expense,
  ];

  static Color series(int index) => palette[index % palette.length];

  /// SIM 1, SIM 2, or grey for an unknown SIM.
  static Color sim(int? slot) =>
      slot == null ? AppColors.textSecondary : series(slot);

  static const double height = 200;
  static const double barWidth = 14;
  static const BorderRadius barRadius = BorderRadius.vertical(
    top: Radius.circular(4),
  );

  static const TextStyle axisLabel = TextStyle(
    fontSize: 11,
    color: AppColors.textSecondary,
  );

  static FlGridData get grid => FlGridData(
    drawVerticalLine: false,
    getDrawingHorizontalLine: (_) =>
        const FlLine(color: AppColors.divider, strokeWidth: 1),
  );

  static FlBorderData get border => FlBorderData(show: false);

  /// "1.2k" style labels for the value axis.
  static String compact(double value) {
    if (value.abs() >= 1000) {
      final k = value / 1000;
      return '${k.toStringAsFixed(k.abs() >= 10 ? 0 : 1)}k';
    }
    return value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
  }

  /// A step for the value axis giving about four grid lines.
  static double interval(double max) {
    if (max <= 0) return 1;
    final raw = max / 4;
    final magnitude = [
      0.1,
      0.2,
      0.5,
      1.0,
      2.0,
      5.0,
      10.0,
      20.0,
      50.0,
      100.0,
      200.0,
      500.0,
      1000.0,
      2000.0,
      5000.0,
      10000.0,
    ];
    return magnitude.firstWhere((m) => m >= raw, orElse: () => raw);
  }

  static BarTouchData touch(String Function(int group, int rod) label) =>
      BarTouchData(
        touchTooltipData: BarTouchTooltipData(
          getTooltipColor: (_) => AppColors.textPrimary,
          getTooltipItem: (group, groupIndex, rod, rodIndex) => BarTooltipItem(
            label(groupIndex, rodIndex),
            const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
      );

  /// Tooltip text for an amount.
  static String money(String name, double value) =>
      '$name\n${Formatters.currency(value)}';
}

/// One coloured series of a [GroupedBarChart].
class ChartSeries {
  const ChartSeries(this.name, this.color, this.values, {this.negativeColor});

  final String name;
  final Color color;

  /// One value per label of the chart.
  final List<double> values;

  /// Colour for values below zero (e.g. a month that cost more than it
  /// earned); [color] when null.
  final Color? negativeColor;

  Color colorFor(double value) =>
      value < 0 && negativeColor != null ? negativeColor! : color;
}

/// Bars grouped by label (e.g. per month), one bar per series (e.g. per SIM),
/// with a legend when there is more than one series.
class GroupedBarChart extends StatelessWidget {
  const GroupedBarChart({
    super.key,
    required this.labels,
    required this.series,
    this.semanticLabel,
    this.highlight,
  });

  final List<String> labels;
  final List<ChartSeries> series;

  /// Read out by screen readers instead of the bars.
  final String? semanticLabel;

  /// When set, only this label's bars are in full colour; the others are
  /// faded (e.g. the chosen month among the last six).
  final int? highlight;

  @override
  Widget build(BuildContext context) {
    final max = series
        .expand((s) => s.values)
        .fold<double>(0, (m, v) => v > m ? v : m);
    // Below-zero values (e.g. net cash flow) get room under a zero line.
    final min = series
        .expand((s) => s.values)
        .fold<double>(0, (m, v) => v < m ? v : m);
    final step = ChartStyle.interval(max > -min ? max : -min);
    final chart = SizedBox(
      height: ChartStyle.height,
      child: BarChart(
        BarChartData(
          maxY: max <= 0 ? (min < 0 ? 0 : 1) : (max / step).ceil() * step,
          minY: min < 0 ? (min / step).floor() * step : 0,
          extraLinesData: min < 0
              ? ExtraLinesData(
                  horizontalLines: [
                    HorizontalLine(
                      y: 0,
                      color: AppColors.textSecondary,
                      strokeWidth: 1,
                    ),
                  ],
                )
              : null,
          gridData: ChartStyle.grid,
          borderData: ChartStyle.border,
          barTouchData: ChartStyle.touch(
            (g, r) => ChartStyle.money(
              series.length > 1
                  ? '${labels[g]} · ${series[r].name}'
                  : labels[g],
              series[r].values[g],
            ),
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
                    style: ChartStyle.axisLabel,
                  ),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 24,
                getTitlesWidget: (value, meta) => SideTitleWidget(
                  meta: meta,
                  child: Text(
                    labels[value.toInt()],
                    style: ChartStyle.axisLabel,
                  ),
                ),
              ),
            ),
          ),
          barGroups: [
            for (var g = 0; g < labels.length; g++)
              BarChartGroupData(
                x: g,
                barsSpace: 4,
                barRods: [
                  for (final s in series)
                    BarChartRodData(
                      toY: s.values[g],
                      color: highlight == null || highlight == g
                          ? s.colorFor(s.values[g])
                          : s.colorFor(s.values[g]).withValues(alpha: 0.35),
                      width: ChartStyle.barWidth,
                      borderRadius: ChartStyle.barRadius,
                    ),
                ],
              ),
          ],
        ),
      ),
    );
    return Semantics(
      label: semanticLabel,
      excludeSemantics: semanticLabel != null,
      child: Column(
        children: [
          chart,
          if (series.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 16,
                children: [
                  for (final s in series)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: s.color,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(s.name, style: ChartStyle.axisLabel),
                      ],
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
