import 'budget_model.dart';
import 'monthly_summary.dart';
import 'transaction_category.dart';
import 'transaction_model.dart';

/// A spending limit for one category in one calendar month.
///
/// Stored at `users/{uid}/categoryBudgets/{YYYY-MM}_{categoryId}`, separate
/// from the overall budget (`budgets/{YYYY-MM}`), which it never changes.
/// Each month has its own limits; past months keep theirs.
class CategoryBudget {
  CategoryBudget({
    required DateTime month,
    required this.categoryId,
    required this.limit,
  }) : month = DateTime(month.year, month.month);

  /// The first day of the limit's month (local time).
  final DateTime month;
  final String categoryId;

  /// Maximum spending in [categoryId] for the month. Always positive.
  final double limit;

  String get monthId => BudgetModel.idFor(month);
  String get id => idFor(month, categoryId);

  /// e.g. October 2026, "food" -> "2026-10_food"
  static String idFor(DateTime month, String categoryId) =>
      '${BudgetModel.idFor(month)}_$categoryId';

  /// Category ids the rules accept: lower-case letters and "_".
  static final validId = RegExp(r'^[a-z_]{1,40}$');

  /// Expense categories a limit can be set for: not income, not the
  /// "Uncategorized" bucket, and not retired categories.
  static bool canHaveLimit(String categoryId) {
    final c = DefaultCategories.byId(categoryId);
    return c.id == categoryId &&
        c.type == TransactionType.expense &&
        c.id != 'uncategorized' &&
        !DefaultCategories.retired.contains(c.id) &&
        validId.hasMatch(c.id);
  }

  /// Categories offered for a new limit (deactivated ones left out).
  static List<TransactionCategory> get budgetable => [
    for (final c in DefaultCategories.all)
      if (canHaveLimit(c.id) && c.active) c,
  ];

  /// What "Copy last month's limits" adds to [current]: [previous]'s limits
  /// for active categories that have none yet. Existing limits are never
  /// replaced.
  static Map<String, double> toCopy(
    Map<String, double> previous,
    Map<String, double> current,
  ) => {
    for (final e in previous.entries)
      if (!current.containsKey(e.key) &&
              canHaveLimit(e.key) &&
              !DefaultCategories.isInactive(e.key))
            e.key: e.value,
  };
}

/// One category's spending against its limit (if it has one) for a month.
class CategoryLimitStatus {
  const CategoryLimitStatus({
    required this.categoryId,
    required this.spent,
    required this.share,
    this.limit,
  });

  final String categoryId;

  /// Net spending (see `Ledger`): never below zero here, so a refund larger
  /// than the month's purchases shows as nothing spent.
  final double spent;

  /// Fraction (0–1) of the month's spending (as in the category chart).
  final double share;
  final double? limit;

  bool get hasLimit => limit != null;

  /// Limit minus spent; negative when over. Null without a limit.
  double? get remaining => limit == null
      ? null
      : MonthlySummary.fromCents(
          MonthlySummary.toCents(limit!) - MonthlySummary.toCents(spent),
        );

  double? get usedFraction => limit == null ? null : spent / limit!;

  /// The same thresholds as the overall budget.
  BudgetStatus? get status {
    if (limit == null) return null;
    if (MonthlySummary.toCents(spent) > MonthlySummary.toCents(limit!)) {
      return BudgetStatus.over;
    }
    if (usedFraction! >= MonthlySummary.nearLimitFraction) {
      return BudgetStatus.nearLimit;
    }
    return BudgetStatus.onTrack;
  }
}

/// A month's category spending combined with its category limits.
///
/// Pure: spending is [MonthlySummary.byCategory] exactly as it is (the
/// Ledger's rules), limits are only compared with it, never mixed in.
class CategoryBudgetSummary {
  CategoryBudgetSummary._(this.rows, this.limits, this.overallBudget);

  factory CategoryBudgetSummary.of(
    MonthlySummary summary,
    Map<String, double> limits,
  ) {
    final spent = {for (final c in summary.byCategory) c.categoryId: c};
    final rows = [
      for (final c in summary.byCategory)
        CategoryLimitStatus(
          categoryId: c.categoryId,
          spent: c.amount,
          share: c.share,
          limit: limits[c.categoryId],
        ),
      // Limits with nothing (or less than nothing) spent this month.
      for (final e in limits.entries)
        if (!spent.containsKey(e.key))
          CategoryLimitStatus(
            categoryId: e.key,
            spent: 0,
            share: 0,
            limit: e.value,
          ),
    ];
    int rank(CategoryLimitStatus r) => switch (r.status) {
      BudgetStatus.over => 0,
      BudgetStatus.nearLimit => 1,
      _ => 2,
    };
    rows.sort((a, b) {
      final byStatus = rank(a).compareTo(rank(b));
      return byStatus != 0 ? byStatus : b.spent.compareTo(a.spent);
    });
    return CategoryBudgetSummary._(rows, limits, summary.budget);
  }

  /// Over-limit first, then near-limit, then by amount spent.
  final List<CategoryLimitStatus> rows;
  final Map<String, double> limits;
  final double? overallBudget;

  int get overCount => rows.where((r) => r.status == BudgetStatus.over).length;
  int get nearCount =>
      rows.where((r) => r.status == BudgetStatus.nearLimit).length;

  double get totalLimits => MonthlySummary.fromCents(
    limits.values.fold(0, (sum, l) => sum + MonthlySummary.toCents(l)),
  );

  /// The category limits add up to more than the overall budget. Only a
  /// warning: neither is changed.
  bool get exceedsOverall =>
      overallBudget != null &&
      MonthlySummary.toCents(totalLimits) >
          MonthlySummary.toCents(overallBudget!);
}
