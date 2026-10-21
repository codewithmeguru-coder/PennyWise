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

/// Income, expenses, budget and category totals for one calendar month.
///
/// Pure calculation: give it the user's transactions, a month and
/// (optionally) that month's budget.
class MonthlySummary {
  MonthlySummary._({
    required this.month,
    required this.income,
    required this.expenses,
    required this.budget,
    required this.byCategory,
    required this.transactionCount,
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
    final inMonth = transactions
        .where((t) => !t.date.isBefore(start) && t.date.isBefore(end))
        .toList();

    // Sum in whole cents so 0.1 + 0.2 is exactly 0.30, not 0.30000000000000004.
    var incomeCents = 0;
    var expenseCents = 0;
    final categoryCents = <String, int>{};
    for (final t in inMonth) {
      final cents = toCents(t.amount);
      if (t.isIncome) {
        incomeCents += cents;
      } else {
        expenseCents += cents;
        categoryCents.update(t.categoryId, (c) => c + cents,
            ifAbsent: () => cents);
      }
    }

    final byCategory = [
      // Skip categories that round to 0 cents (e.g. 0.001 written by another
      // client): they'd draw nothing and, if they were the only spending,
      // would divide 0 by 0.
      for (final entry in categoryCents.entries)
        if (entry.value > 0)
          CategorySpend(
            categoryId: entry.key,
            amount: fromCents(entry.value),
            share: entry.value / expenseCents,
          ),
    ]..sort((a, b) => b.amount.compareTo(a.amount)); // largest first

    return MonthlySummary._(
      month: start,
      income: fromCents(incomeCents),
      expenses: fromCents(expenseCents),
      budget: budget,
      byCategory: byCategory,
      transactionCount: inMonth.length,
    );
  }

  final DateTime month;
  final double income;
  final double expenses;

  /// The month's budget, or null if none is set.
  final double? budget;

  /// Expenses grouped by category, largest first. Empty if no expenses.
  final List<CategorySpend> byCategory;

  /// Number of transactions (income and expense) in the month.
  final int transactionCount;

  bool get hasBudget => budget != null;

  /// Income minus expenses. Negative if the month cost more than it earned.
  double get net => fromCents(toCents(income) - toCents(expenses));

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

  static int toCents(double amount) => (amount * 100).round();
  static double fromCents(int cents) => cents / 100;
}
