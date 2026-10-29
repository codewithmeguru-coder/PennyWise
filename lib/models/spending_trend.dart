import 'ledger.dart';
import 'monthly_summary.dart';
import 'transaction_model.dart';

/// Spending over time, for charts. Every figure is [Ledger.spending] (or
/// [MonthlySummary.expenses]) over a slice of the transactions, so the
/// accounting rules are exactly those of the rest of the app: transfers,
/// savings and loan principal are not spending; fees and interest are;
/// refunds reduce it.
class SpendingTrend {
  SpendingTrend._();

  /// Spending from the start of [month] to the end of each day, for day 1
  /// up to the month's last day, or up to [today] in the current month.
  /// Refunds can make it go down.
  static List<double> cumulativeByDay(
    List<TransactionModel> transactions,
    DateTime month, {
    DateTime? today,
  }) {
    final start = DateTime(month.year, month.month);
    final now = today ?? DateTime.now();
    final lastDay = DateTime(month.year, month.month + 1, 0).day;
    final days = start.year == now.year && start.month == now.month
        ? now.day
        : (start.isAfter(now) ? 0 : lastDay);
    final inMonth = [
      for (final t in transactions)
        if (!t.date.isBefore(start) &&
            t.date.isBefore(DateTime(month.year, month.month + 1)))
          t,
    ];
    return [
      for (var day = 1; day <= days; day++)
        Ledger.of(
          inMonth.where(
            (t) => t.date.isBefore(DateTime(month.year, month.month, day + 1)),
          ),
        ).spending,
    ];
  }

  /// The [count] months ending with [month], oldest first, with what each
  /// cost (see [MonthlySummary.expenses]).
  static List<(DateTime, double)> monthlyTotals(
    List<TransactionModel> transactions,
    DateTime month, {
    int count = 6,
  }) => [
    for (var i = count - 1; i >= 0; i--)
      () {
        final m = DateTime(month.year, month.month - i);
        return (
          m,
          MonthlySummary.calculate(
            transactions: transactions,
            month: m,
          ).expenses,
        );
      }(),
  ];
}
