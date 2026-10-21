import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/models/monthly_summary.dart';
import 'package:pennywise/models/transaction_model.dart';

TransactionModel tx(
  double amount,
  DateTime date, {
  TransactionType type = TransactionType.expense,
  String category = 'food',
}) =>
    TransactionModel(
      description: 'x',
      amount: amount,
      type: type,
      categoryId: category,
      date: date,
    );

void main() {
  final september = DateTime(2026, 9);

  test('only counts transactions inside the selected month', () {
    final summary = MonthlySummary.calculate(
      month: september,
      transactions: [
        tx(10, DateTime(2026, 8, 31, 23, 59)), // August: excluded
        tx(20, DateTime(2026, 9, 1)), // first instant: included
        tx(30, DateTime(2026, 9, 30, 23, 59, 59)), // last second: included
        tx(40, DateTime(2026, 10, 1)), // October: excluded
      ],
    );

    expect(summary.expenses, 50);
    expect(summary.transactionCount, 2);
  });

  test('December rolls over to January correctly', () {
    final summary = MonthlySummary.calculate(
      month: DateTime(2026, 12),
      transactions: [
        tx(5, DateTime(2026, 12, 31, 22)),
        tx(7, DateTime(2027, 1, 1)),
      ],
    );

    expect(summary.expenses, 5);
  });

  test('sums income and expenses separately; net is the difference', () {
    final summary = MonthlySummary.calculate(
      month: september,
      transactions: [
        tx(65000, DateTime(2026, 9, 1), type: TransactionType.income),
        tx(12000, DateTime(2026, 9, 3), type: TransactionType.income),
        tx(850, DateTime(2026, 9, 2)),
        tx(3240, DateTime(2026, 9, 4), category: 'shopping'),
      ],
    );

    expect(summary.income, 77000);
    expect(summary.expenses, 4090);
    expect(summary.net, 72910);
  });

  test('sums in cents, avoiding floating-point drift', () {
    final summary = MonthlySummary.calculate(
      month: september,
      transactions: [
        tx(0.1, DateTime(2026, 9, 1)),
        tx(0.2, DateTime(2026, 9, 1)),
      ],
      budget: 0.3,
    );

    expect(summary.expenses, 0.3); // not 0.30000000000000004
    expect(summary.remaining, 0);
  });

  test('remaining, used fraction and status against a budget', () {
    MonthlySummary withSpend(double spent) => MonthlySummary.calculate(
          month: september,
          transactions: [tx(spent, DateTime(2026, 9, 10))],
          budget: 1000,
        );

    final onTrack = withSpend(250);
    expect(onTrack.remaining, 750);
    expect(onTrack.usedFraction, 0.25);
    expect(onTrack.status, BudgetStatus.onTrack);

    expect(withSpend(800).status, BudgetStatus.nearLimit); // 80% exactly
    expect(withSpend(1000).status, BudgetStatus.nearLimit); // at the limit
    expect(withSpend(1000).remaining, 0);

    final over = withSpend(1200);
    expect(over.status, BudgetStatus.over);
    expect(over.remaining, -200);
  });

  test('income does not count against the budget', () {
    final summary = MonthlySummary.calculate(
      month: september,
      transactions: [
        tx(5000, DateTime(2026, 9, 1), type: TransactionType.income),
        tx(100, DateTime(2026, 9, 1)),
      ],
      budget: 1000,
    );

    expect(summary.remaining, 900);
  });

  test('groups expenses by category, largest first, with shares', () {
    final summary = MonthlySummary.calculate(
      month: september,
      transactions: [
        tx(100, DateTime(2026, 9, 1), category: 'food'),
        tx(200, DateTime(2026, 9, 2), category: 'food'),
        tx(600, DateTime(2026, 9, 3), category: 'bills'),
        tx(100, DateTime(2026, 9, 4), category: 'transport'),
        tx(9999, DateTime(2026, 9, 5),
            type: TransactionType.income, category: 'salary'),
      ],
    );

    expect(summary.byCategory.map((c) => c.categoryId),
        ['bills', 'food', 'transport']);
    expect(summary.byCategory.map((c) => c.amount), [600, 300, 100]);
    expect(summary.byCategory.map((c) => c.share), [0.6, 0.3, 0.1]);
  });

  test('empty month: zeros, no categories, no budget status', () {
    final summary =
        MonthlySummary.calculate(month: september, transactions: const []);

    expect(summary.income, 0);
    expect(summary.expenses, 0);
    expect(summary.net, 0);
    expect(summary.byCategory, isEmpty);
    expect(summary.hasBudget, isFalse);
    expect(summary.remaining, isNull);
    expect(summary.status, isNull);
  });

  test('a budget with no spending is fully remaining', () {
    final summary = MonthlySummary.calculate(
      month: september,
      transactions: const [],
      budget: 5000,
    );

    expect(summary.remaining, 5000);
    expect(summary.usedFraction, 0);
    expect(summary.status, BudgetStatus.onTrack);
  });
}
