import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../privacy/savings_privacy.dart';
import '../../utils/formatters.dart';
import 'chart_style.dart';

/// One bar per label (e.g. per month), stacked from [series] in order
/// (bottom first), with a legend. Tapping a legend entry calls [onSelect]
/// with its index, e.g. to focus on that category.
class StackedBarChart extends StatelessWidget {
  const StackedBarChart({
    super.key,
    required this.labels,
    required this.series,
    this.onSelect,
    this.semanticLabel,
  });

  final List<String> labels;

  /// Values must be zero or more; one per label.
  final List<ChartSeries> series;
  final ValueChanged<int>? onSelect;
  final String? semanticLabel;

  double _total(int g) => series.fold(0.0, (sum, s) => sum + s.values[g]);

  @override
  Widget build(BuildContext context) {
    final max = [for (var g = 0; g < labels.length; g++) _total(g)]
        .fold<double>(0, (m, v) => v > m ? v : m);
    final step = ChartStyle.interval(max);
    return Semantics(
      label: semanticLabel,
      excludeSemantics: semanticLabel != null,
      child: Column(
        children: [
          SizedBox(
            height: ChartStyle.height,
            child: BarChart(
              BarChartData(
                maxY: max <= 0 ? 1 : (max / step).ceil() * step,
                gridData: ChartStyle.grid(context),
                borderData: ChartStyle.border,
                barTouchData: ChartStyle.touch(context, 
                  (g, _) => ChartStyle.money(context, labels[g], _total(g)),
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
                          ChartStyle.axis(context, value),
                          style: ChartStyle.axisLabel(context),
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
                          style: ChartStyle.axisLabel(context),
                        ),
                      ),
                    ),
                  ),
                ),
                barGroups: [
                  for (var g = 0; g < labels.length; g++)
                    BarChartGroupData(
                      x: g,
                      barRods: [
                        BarChartRodData(
                          toY: _total(g),
                          width: ChartStyle.barWidth * 1.6,
                          borderRadius: ChartStyle.barRadius,
                          color: Colors.transparent,
                          rodStackItems: _stack(g),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 4,
            runSpacing: 0,
            children: [
              for (var i = 0; i < series.length; i++)
                InkWell(
                  onTap: onSelect == null ? null : () => onSelect!(i),
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: series[i].color,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(series[i].name, style: ChartStyle.axisLabel(context)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  List<BarChartRodStackItem> _stack(int g) {
    final items = <BarChartRodStackItem>[];
    var from = 0.0;
    for (final s in series) {
      final v = s.values[g];
      if (v <= 0) continue;
      items.add(BarChartRodStackItem(from, from + v, s.color));
      from += v;
    }
    return items;
  }

  /// "Oct: Food KSh 1,200.00, Other KSh 300.00", for screen readers.
  static String describe(List<String> labels, List<ChartSeries> series,
          {bool hidden = false}) => [
    for (var g = 0; g < labels.length; g++)
      '${labels[g]}: ${[for (final s in series)
        if (s.values[g] > 0) '${s.name} ${hidden ? SavingsPrivacyController.mask : Formatters.currency(s.values[g])}'].join(', ')}',
  ].join('; ');
}
