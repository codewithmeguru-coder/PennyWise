import 'monthly_summary.dart';
import 'transaction_model.dart';

/// A figure now and in the month it's compared with.
class TrendChange {
  const TrendChange(this.current, this.previous);

  final double current;
  final double previous;

  /// Now minus before, exact to the cent.
  double get change => MonthlySummary.fromCents(
    MonthlySummary.toCents(current) - MonthlySummary.toCents(previous),
  );

  /// Change as a percentage of before; null when before was 0 ("new").
  double? get percent => MonthlySummary.toCents(previous) == 0
      ? null
      : change / previous.abs() * 100;
}

/// One category's spending now and in the comparison month.
class CategoryMove {
  const CategoryMove(this.categoryId, this.amounts);

  final String categoryId;
  final TrendChange amounts;
}

/// How the selected month compares with the month before it.
///
/// For the current month, which isn't over, both sides cover the same
/// elapsed days: 1–27 Oct against 1–27 Sep. When the previous month is
/// shorter (31 Oct against September), it is capped at its last day.
class TrendComparison {
  const TrendComparison({
    required this.month,
    required this.previousMonth,
    required this.partialDay,
    required this.income,
    required this.expenses,
    required this.net,
    required this.saved,
    required this.increases,
    required this.decreases,
  });

  final DateTime month;
  final DateTime previousMonth;

  /// Null for a full month. Otherwise the last day counted this month; the
  /// previous month is counted to [previousDay].
  final int? partialDay;
  bool get isPartial => partialDay != null;

  /// The last day counted in the previous month.
  int get previousDay {
    final last = DateTime(previousMonth.year, previousMonth.month + 1, 0).day;
    return partialDay == null || partialDay! > last ? last : partialDay!;
  }

  final TrendChange income, expenses, net, saved;

  /// Largest category increases / decreases first (at most three each,
  /// ignoring moves under [MonthlyTrend.noiseFloor]).
  final List<CategoryMove> increases, decreases;
}

/// Month-by-month figures for a range of months, from the user's saved
/// transactions. Pure: every month is [MonthlySummary.calculate], exactly
/// what Home and Budgets show for it, so the accounting rules are the
/// Ledger's (transfers, savings and loan principal aren't spending; fees and
/// interest are; refunds reduce their own category).
class MonthlyTrend {
  MonthlyTrend._({
    required this.end,
    required this.range,
    required this.months,
    required this.firstMonth,
    required this.historyMonths,
    required this.comparison,
    required this.topCategories,
  });

  /// Category moves smaller than this (KSh) are left out as noise.
  static const noiseFloor = 50.0;

  /// How many categories get their own colour in the stacked chart.
  static const topCount = 5;

  factory MonthlyTrend.build(
    List<TransactionModel> transactions, {
    required DateTime end,
    int range = 6,
    DateTime? today,
  }) {
    final now = today ?? DateTime.now();
    final endMonth = DateTime(end.year, end.month);
    DateTime? first;
    for (final t in transactions) {
      final m = DateTime(t.date.year, t.date.month);
      if (first == null || m.isBefore(first)) first = m;
    }

    final months = <MonthlySummary>[];
    if (first != null) {
      for (var i = range - 1; i >= 0; i--) {
        final m = DateTime(endMonth.year, endMonth.month - i);
        if (m.isBefore(first)) continue; // before history: not drawn as 0
        months.add(
          MonthlySummary.calculate(transactions: transactions, month: m),
        );
      }
    }

    final current = DateTime(now.year, now.month);
    final history = first == null
        ? 0
        : (current.year - first.year) * 12 + current.month - first.month + 1;

    // Top categories over the whole range, by total spending.
    final totals = <String, int>{};
    for (final s in months) {
      for (final c in s.byCategory) {
        totals[c.categoryId] =
            (totals[c.categoryId] ?? 0) + MonthlySummary.toCents(c.amount);
      }
    }
    final top =
        (totals.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
            .take(topCount)
            .map((e) => e.key)
            .toList();

    return MonthlyTrend._(
      end: endMonth,
      range: range,
      months: months,
      firstMonth: first,
      historyMonths: history < 0 ? 0 : history,
      comparison: first == null
          ? null
          : _compare(transactions, endMonth, first, now),
      topCategories: top,
    );
  }

  static TrendComparison? _compare(
    List<TransactionModel> ts,
    DateTime month,
    DateTime first,
    DateTime now,
  ) {
    final previous = DateTime(month.year, month.month - 1);
    if (previous.isBefore(first)) return null; // nothing to compare with
    final partial = month.year == now.year && month.month == now.month;
    final day = partial ? now.day : null;

    MonthlySummary upTo(DateTime m, int? lastDay) => MonthlySummary.calculate(
      transactions: lastDay == null
          ? ts
          : [
              for (final t in ts)
                if (t.date.isBefore(DateTime(m.year, m.month, lastDay + 1))) t,
            ],
      month: m,
    );

    final prevLast = DateTime(previous.year, previous.month + 1, 0).day;
    final cur = upTo(month, day);
    final before = upTo(previous, day == null || day > prevLast ? null : day);

    final ids = {
      for (final c in cur.byCategory) c.categoryId,
      for (final c in before.byCategory) c.categoryId,
    };
    double spentIn(MonthlySummary s, String id) {
      for (final c in s.byCategory) {
        if (c.categoryId == id) return c.amount;
      }
      return 0;
    }

    final moves =
        [
          for (final id in ids)
            CategoryMove(
              id,
              TrendChange(spentIn(cur, id), spentIn(before, id)),
            ),
        ].where((m) => m.amounts.change.abs() >= noiseFloor).toList()..sort(
          (a, b) => b.amounts.change.abs().compareTo(a.amounts.change.abs()),
        );

    return TrendComparison(
      month: month,
      previousMonth: previous,
      partialDay: day,
      income: TrendChange(cur.income, before.income),
      expenses: TrendChange(cur.expenses, before.expenses),
      net: TrendChange(cur.net, before.net),
      saved: TrendChange(cur.netSaved, before.netSaved),
      increases: [
        for (final m in moves)
          if (m.amounts.change > 0) m,
      ].take(3).toList(),
      decreases: [
        for (final m in moves)
          if (m.amounts.change < 0) m,
      ].take(3).toList(),
    );
  }

  /// The selected (last) month.
  final DateTime end;

  /// The months asked for (3, 6 or 12); [months] can hold fewer.
  final int range;

  /// The months shown, oldest first: the range, minus months before the
  /// first transaction.
  final List<MonthlySummary> months;

  /// The month of the first transaction; null without any.
  final DateTime? firstMonth;

  /// Months from [firstMonth] to the current month.
  final int historyMonths;

  /// The selected month against the one before; null without two months.
  final TrendComparison? comparison;

  /// The [topCount] categories with the most spending over [months].
  final List<String> topCategories;

  bool get isEmpty => firstMonth == null;

  /// One category's spending in each of [months].
  List<double> categoryByMonth(String id) => [
    for (final s in months)
      s.byCategory
          .firstWhere(
            (c) => c.categoryId == id,
            orElse: () => CategorySpend(categoryId: id, amount: 0, share: 0),
          )
          .amount,
  ];

  /// Spending outside [topCategories] in each of [months], so the stack's
  /// parts add up to the month's total by category.
  List<double> otherByMonth() => [
    for (final s in months)
      MonthlySummary.fromCents(
        s.byCategory
            .where((c) => !topCategories.contains(c.categoryId))
            .fold(0, (sum, c) => sum + MonthlySummary.toCents(c.amount)),
      ),
  ];
}
