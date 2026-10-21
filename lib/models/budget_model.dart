/// The user's overall spending limit for one calendar month.
///
/// Stored at `users/{uid}/budgets/{YYYY-MM}`, so each month has at most one
/// budget and past months keep the budget they had at the time.
class BudgetModel {
  BudgetModel({required DateTime month, required this.limit})
      : month = DateTime(month.year, month.month);

  /// The first day of the budget's month (local time).
  final DateTime month;

  /// Maximum total expenses for the month. Always positive.
  final double limit;

  String get monthId => idFor(month);

  /// e.g. September 2026 -> "2026-09"
  static String idFor(DateTime month) =>
      '${month.year.toString().padLeft(4, '0')}-'
      '${month.month.toString().padLeft(2, '0')}';
}
