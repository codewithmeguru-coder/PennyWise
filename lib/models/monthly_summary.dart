import 'ledger.dart';
import 'transaction_model.dart';

/// Total spent in one expense category during a month.
class CategorySpend {
  const CategorySpend({
    required this.categoryId,
    required this.amount,
    required this.share,
  });

  final String categoryId;
  final double amount;

  /// Fraction (0–1) of the month's total expenses.
  final double share;
}

/// How the month's spending compares with its budget.
enum BudgetStatus {
  /// Less than [MonthlySummary.nearLimitFraction] of the budget used.
  onTrack,

  /// At least [MonthlySummary.nearLimitFraction] used, but not over.
  nearLimit,

  /// Expenses are above the budget.
  over,
}

/// Income, spending, budget and category totals for one calendar month.
///
/// Pure calculation: give it the user's transactions, a month and
/// (optionally) that month's budget. The money rules (what counts as
/// spending, what is only a transfer or savings) live in [Ledger].
class MonthlySummary {
  MonthlySummary._({
    required this.month,
    required this.ledger,
    required this.budget,
    required this.byCategory,
  });

  /// Budgets turn "near limit" at 80% used.
  static const nearLimitFraction = 0.8;

  factory MonthlySummary.calculate({
    required List<TransactionModel> transactions,
    required DateTime month,
    double? budget,
  }) {
    // The month is [first day 00:00, first day of next month 00:00) in local
    // time. DateTime(year, 13) rolls over to January of the next year.
    final start = DateTime(month.year, month.month);
    final end = DateTime(month.year, month.month + 1);
    final ledger = Ledger.of(transactions
        .where((t) => !t.date.isBefore(start) && t.date.isBefore(end)));

    // Shares are of the positive categories only, so they add up to 100%
    // even when a refund pushed another category below zero. Categories that
    // round to 0 cents are skipped: they'd draw nothing and, if they were
    // the only spending, would divide 0 by 0.
    final categories = ledger.spendingByCategory;
    final total = categories.fold(0, (sum, e) => sum + e.value);
    final byCategory = [
      for (final entry in categories)
        CategorySpend(
          categoryId: entry.key,
          amount: fromCents(entry.value),
          share: entry.value / total,
        ),
    ];

    return MonthlySummary._(
      month: start,
      ledger: ledger,
      budget: budget,
      byCategory: byCategory,
    );
  }

  /// The month's full totals (savings, fees, refunds, accounts...).
  final Ledger ledger;

  final DateTime month;

  /// Money earned in the month.
  double get income => ledger.income;

  /// What the month cost: expenses + fees + interest − refunds. Transfers,
  /// savings and loan principal are not included.
  double get expenses => ledger.spending;

  /// The month's budget, or null if none is set.
  final double? budget;

  /// Spending grouped by category, largest first. Empty if no spending.
  final List<CategorySpend> byCategory;

  /// Number of transactions of any type in the month.
  int get transactionCount => ledger.transactionCount;

  /// Money moved into savings minus money taken out, this month.
  double get netSaved => ledger.netSaved;

  bool get hasBudget => budget != null;

  /// Income minus spending. Negative if the month cost more than it earned.
  double get net => ledger.net;

  /// Budget minus expenses. Negative when over budget; null without a budget.
  double? get remaining =>
      budget == null ? null : fromCents(toCents(budget!) - toCents(expenses));

  /// Expenses divided by budget (1.0 = exactly on budget, can exceed 1).
  double? get usedFraction => budget == null ? null : expenses / budget!;

  BudgetStatus? get status {
    final used = usedFraction;
    if (used == null) return null;
    if (used > 1) return BudgetStatus.over;
    if (used >= nearLimitFraction) return BudgetStatus.nearLimit;
    return BudgetStatus.onTrack;
  }

  static int toCents(double amount) => Ledger.toCents(amount);
  static double fromCents(int cents) => Ledger.fromCents(cents);
}
