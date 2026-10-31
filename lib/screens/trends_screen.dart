import 'package:flutter/material.dart';

import '../data/transaction_store.dart';
import '../models/month_selection.dart';
import '../models/monthly_trend.dart';
import '../models/transaction_category.dart';
import '../privacy/savings_privacy.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';
import '../widgets/charts/chart_style.dart';
import '../widgets/charts/stacked_bar_chart.dart';
import '../widgets/empty_state.dart';
import '../widgets/month_switcher.dart';
import '../widgets/section_header.dart';

/// Month-by-month trends up to the shared [month]: the selected month
/// against the one before (same elapsed days for the current month),
/// income vs expenses, net cash flow, spending by category, and the biggest
/// category changes. Read-only; every figure is a month's
/// `MonthlySummary`, as on Home and Budgets.
class TrendsScreen extends StatefulWidget {
  const TrendsScreen({super.key, required this.store, required this.month});

  final TransactionStore store;
  final MonthSelection month;

  @override
  State<TrendsScreen> createState() => _TrendsScreenState();
}

class _TrendsScreenState extends State<TrendsScreen> {
  static const ranges = [3, 6, 12];
  var _range = 6;

  /// The category in focus, or null for the stacked view of all.
  String? _focus;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Trends')),
      body: ListenableBuilder(
        listenable: Listenable.merge([widget.store, widget.month]),
        builder: (context, _) => _body(),
      ),
    );
  }

  Widget _body() {
    final store = widget.store;
    if (store.error != null) {
      return EmptyState(
        icon: Icons.cloud_off_rounded,
        title: 'Couldn\'t load transactions',
        message: store.error!,
        actionLabel: 'Retry',
        onAction: store.retry,
      );
    }
    if (store.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final trend = MonthlyTrend.build(
      store.transactions,
      end: widget.month.value,
      range: _range,
    );
    if (trend.isEmpty) {
      return const EmptyState(
        icon: Icons.insights_rounded,
        title: 'No transactions yet',
        message: 'Trends appear once you have transactions.',
      );
    }
    final labels = [for (final m in trend.months) _short(m.month)];
    final now = DateTime.now();
    final showsCurrent =
        trend.months.isNotEmpty &&
        trend.months.last.month == DateTime(now.year, now.month);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        MonthSwitcher(selection: widget.month),
        Wrap(
          spacing: 8,
          children: [
            for (final r in ranges)
              ChoiceChip(
                label: Text('$r months'),
                selected: _range == r,
                onSelected: (_) => setState(() => _range = r),
              ),
          ],
        ),
        const SizedBox(height: 8),
        _Note(_historyNote(trend)),
        if (showsCurrent)
          _Note(
            '${Formatters.monthYear(now)} is so far, to '
            '${Formatters.shortDate(now)}.',
          ),
        const SizedBox(height: 8),
        _ComparisonCard(trend: trend),
        if (trend.months.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text(
              'No history in this range.',
              textAlign: TextAlign.center,
              style: TextStyle(color: context.colors.textSecondary),
            ),
          )
        else ...[
          const SectionHeader(title: 'Income vs expenses'),
          _card(
            GroupedBarChart(
              labels: labels,
              series: [
                ChartSeries('Income', context.colors.income, [
                  for (final m in trend.months) m.income,
                ]),
                ChartSeries('Expenses', context.colors.expense, [
                  for (final m in trend.months) m.expenses,
                ]),
              ],
              semanticLabel: [
                for (final m in trend.months)
                  '${Formatters.monthYear(m.month)}: income '
                      '${Formatters.currency(m.income)}, expenses '
                      '${Formatters.currency(m.expenses)}',
              ].join('; '),
            ),
          ),
          const SectionHeader(title: 'Net cash flow'),
          _card(
            GroupedBarChart(
              labels: labels,
              series: [
                ChartSeries('Net', context.colors.income, [
                  for (final m in trend.months) m.net,
                ], negativeColor: context.colors.expense),
              ],
              semanticLabel: [
                for (final m in trend.months)
                  '${Formatters.monthYear(m.month)}: net '
                      '${Formatters.currency(m.net)}',
              ].join('; '),
            ),
          ),
          _Note(
            'Income minus spending. Money moved to savings '
            '(${[for (final m in trend.months) '${_short(m.month)} ${SavingsPrivacy.amount(context, m.netSaved)}'].join(', ')}) is shown here, not counted as spending.',
          ),
          const SectionHeader(title: 'Spending by category'),
          _card(_categoryChart(trend, labels)),
          if (trend.comparison case final c?)
            _Movers(
              comparison: c,
              onFocus: (id) => setState(() => _focus = id),
            ),
        ],
      ],
    );
  }

  Widget _categoryChart(MonthlyTrend trend, List<String> labels) {
    final focus = _focus;
    if (focus != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  trendName(focus),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              TextButton(
                onPressed: () => setState(() => _focus = null),
                child: const Text('Show all'),
              ),
            ],
          ),
          GroupedBarChart(
            labels: labels,
            series: [
              ChartSeries(
                trendName(focus),
                ChartStyle.series(context, 0),
                trend.categoryByMonth(focus),
              ),
            ],
            highlight: labels.length - 1,
          ),
        ],
      );
    }
    final top = trend.topCategories;
    if (top.isEmpty) {
      return Text(
        'No spending in this range.',
        style: TextStyle(color: context.colors.textSecondary),
      );
    }
    final series = [
      for (var i = 0; i < top.length; i++)
        ChartSeries(
          trendName(top[i]),
          ChartStyle.series(context, i),
          trend.categoryByMonth(top[i]),
        ),
      ChartSeries('Other', context.colors.textSecondary, trend.otherByMonth()),
    ];
    return StackedBarChart(
      labels: labels,
      series: series,
      onSelect: (i) {
        if (i < top.length) setState(() => _focus = top[i]);
      },
      semanticLabel: StackedBarChart.describe(labels, series),
    );
  }

  static String _historyNote(MonthlyTrend trend) {
    final n = trend.historyMonths;
    final since = Formatters.monthYear(trend.firstMonth!);
    final shown = trend.months.length;
    return 'History: $n ${n == 1 ? 'month' : 'months'}, since $since.'
        '${shown < trend.range ? ' Showing the $shown in this range that '
                  'have history.' : ''}';
  }

  Widget _card(Widget child) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(8, 16, 16, 12),
      child: child,
    ),
  );

  static String _short(DateTime m) => Formatters.monthYear(m).substring(0, 3);
}

/// A category's name in trends; turned-off ones are marked "(off)".
String trendName(String id) {
  final c = DefaultCategories.byId(id);
  return c.active ? c.name : '${c.name} (off)';
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Text(
      text,
      style: TextStyle(fontSize: 12, color: context.colors.textSecondary),
    ),
  );
}

/// The selected month against the one before.
class _ComparisonCard extends StatelessWidget {
  const _ComparisonCard({required this.trend});

  final MonthlyTrend trend;

  @override
  Widget build(BuildContext context) {
    final c = trend.comparison;
    if (c == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Comparisons start once there are two months of '
            'history.',
          ),
        ),
      );
    }
    final month = Formatters.monthYear(c.month);
    final prev = Formatters.monthYear(c.previousMonth);
    final title = c.isPartial
        ? '1–${c.partialDay} ${month.split(' ').first} so far vs '
              '1–${c.previousDay} ${prev.split(' ').first}'
        : '$month vs $prev';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            if (c.isPartial)
              const _Note('Part of the month only: not a full-month result.'),
            const SizedBox(height: 8),
            _ChangeRow(label: 'Income', change: c.income, upIsGood: true),
            _ChangeRow(label: 'Expenses', change: c.expenses, upIsGood: false),
            _ChangeRow(label: 'Net', change: c.net, upIsGood: true),
            _ChangeRow(label: 'Saved', change: c.saved, upIsGood: true),
          ],
        ),
      ),
    );
  }
}

/// "KSh 12,400.00   ▲ KSh 1,850.00 (+17.5%)", coloured by meaning.
class _ChangeRow extends StatelessWidget {
  const _ChangeRow({
    required this.label,
    required this.change,
    required this.upIsGood,
  });

  final String label;
  final TrendChange change;
  final bool upIsGood;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: TextStyle(color: context.colors.textSecondary),
            ),
          ),
          Expanded(
            child: Text(
              Formatters.currency(change.current),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Flexible(child: changeText(context, change, upIsGood: upIsGood)),
        ],
      ),
    );
  }
}

/// "▲ KSh 1,850.00 (+17.5%)", "▼ …", "No change", or "new".
Widget changeText(
  BuildContext context,
  TrendChange c, {
  required bool upIsGood,
}) {
  final diff = c.change;
  if (diff == 0) {
    return Text(
      'No change',
      style: TextStyle(fontSize: 12, color: context.colors.textSecondary),
    );
  }
  final up = diff > 0;
  final good = up == upIsGood;
  final pct = c.percent;
  return Text(
    '${up ? '▲' : '▼'} ${Formatters.currency(diff.abs())}'
    '${pct == null ? ' (new)' : ' (${up ? '+' : '-'}${pct.abs().toStringAsFixed(1)}%)'}',
    textAlign: TextAlign.right,
    style: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: good ? context.colors.income : context.colors.expense,
    ),
  );
}

/// The biggest category increases and decreases vs the previous month.
class _Movers extends StatelessWidget {
  const _Movers({required this.comparison, required this.onFocus});

  final TrendComparison comparison;
  final ValueChanged<String> onFocus;

  @override
  Widget build(BuildContext context) {
    final c = comparison;
    Widget list(String title, List<CategoryMove> moves) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        if (moves.isEmpty)
          const _Note('None over KSh 50.')
        else
          for (final m in moves)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                DefaultCategories.byId(m.categoryId).icon,
                size: 20,
              ),
              title: Text(trendName(m.categoryId)),
              subtitle: Text(
                '${Formatters.currency(m.amounts.previous)}'
                ' → ${Formatters.currency(m.amounts.current)}',
              ),
              trailing: changeText(context, m.amounts, upIsGood: false),
              onTap: () => onFocus(m.categoryId),
            ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: c.isPartial
              ? 'Biggest changes (same days)'
              : 'Biggest changes',
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                list('Spending up', c.increases),
                const SizedBox(height: 8),
                list('Spending down', c.decreases),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
