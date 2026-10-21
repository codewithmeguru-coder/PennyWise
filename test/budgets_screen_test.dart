import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/models/budget_model.dart';
import 'package:pennywise/models/transaction_model.dart';
import 'package:pennywise/utils/formatters.dart';

import 'fake_budget_repository.dart';
import 'fake_transaction_repository.dart';
import 'test_app.dart';

final now = DateTime.now();
final thisMonth = DateTime(now.year, now.month);
final lastMonth = DateTime(now.year, now.month - 1);

TransactionModel tx(
  String id,
  double amount,
  DateTime date, {
  TransactionType type = TransactionType.expense,
  String category = 'food',
}) =>
    TransactionModel(
      id: id,
      description: 'Item $id',
      amount: amount,
      type: type,
      categoryId: category,
      date: date,
    );

/// This month: 850 food + 150 transport spent, 5,000 earned.
/// Last month: 2,000 on bills.
FakeTransactionRepository sampleRepo() => FakeTransactionRepository([
      tx('a', 850, thisMonth.add(const Duration(hours: 12))),
      tx('b', 150, thisMonth.add(const Duration(hours: 13)),
          category: 'transport'),
      tx('c', 5000, thisMonth.add(const Duration(hours: 9)),
          type: TransactionType.income, category: 'salary'),
      tx('d', 2000, lastMonth.add(const Duration(days: 3)), category: 'bills'),
    ]);

Future<void> openBudgets(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.savings_outlined));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows income, expenses, net and categories for this month',
      (tester) async {
    await pumpApp(tester, repository: sampleRepo());
    await openBudgets(tester);

    expect(find.text(Formatters.monthYear(thisMonth)), findsOneWidget);
    expect(find.text('No budget for ${Formatters.monthYear(thisMonth)}'),
        findsOneWidget);
    expect(find.text('KSh 5,000.00'), findsOneWidget); // income
    expect(find.text('KSh 1,000.00'), findsOneWidget); // expenses
    expect(find.text('+KSh 4,000.00'), findsOneWidget); // net

    await tester.scrollUntilVisible(find.text('Transport'), 200);
    expect(find.text('Food'), findsOneWidget);
    expect(find.text('85%'), findsOneWidget);
    expect(find.text('15%'), findsOneWidget);
    expect(find.text('Bills'), findsNothing); // last month's spending
  });

  testWidgets('setting a budget shows what is left', (tester) async {
    final budgets = FakeBudgetRepository();
    await pumpApp(tester, repository: sampleRepo(), budgets: budgets);
    await openBudgets(tester);

    await tester.tap(find.text('Set budget'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '4000');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(budgets.limitFor(thisMonth), 4000);
    expect(find.text('Remaining'), findsOneWidget);
    expect(find.text('KSh 3,000.00'), findsOneWidget); // 4,000 - 1,000
    expect(find.text('On track'), findsOneWidget);
  });

  testWidgets('budget dialog validates the amount', (tester) async {
    await pumpApp(tester, repository: sampleRepo());
    await openBudgets(tester);

    await tester.tap(find.text('Set budget'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '0');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Amount must be greater than 0'), findsOneWidget);
  });

  testWidgets('near-limit and over-budget states', (tester) async {
    final budgets =
        FakeBudgetRepository([BudgetModel(month: thisMonth, limit: 1100)]);
    await pumpApp(tester, repository: sampleRepo(), budgets: budgets);
    await openBudgets(tester);

    expect(find.text('Near limit'), findsOneWidget); // 1,000 of 1,100 = 91%

    await budgets.save(BudgetModel(month: thisMonth, limit: 600));
    await tester.pumpAndSettle();

    expect(find.text('Over budget'), findsOneWidget);
    expect(find.text('Over budget by'), findsOneWidget);
    expect(find.text('KSh 400.00'), findsOneWidget); // 1,000 - 600
  });

  testWidgets('switching month recalculates for that month', (tester) async {
    final budgets =
        FakeBudgetRepository([BudgetModel(month: lastMonth, limit: 2500)]);
    await pumpApp(tester, repository: sampleRepo(), budgets: budgets);
    await openBudgets(tester);

    // Can't go past the current month.
    final next = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.chevron_right_rounded));
    expect(next.onPressed, isNull);

    await tester.tap(find.byTooltip('Previous month'));
    await tester.pumpAndSettle();

    expect(find.text(Formatters.monthYear(lastMonth)), findsOneWidget);
    expect(find.text('KSh 500.00'), findsOneWidget); // 2,500 - 2,000 left
    expect(find.text('Bills'), findsOneWidget);
    expect(find.text('Food'), findsNothing);
  });

  testWidgets('removing a budget', (tester) async {
    final budgets =
        FakeBudgetRepository([BudgetModel(month: thisMonth, limit: 4000)]);
    await pumpApp(tester, repository: sampleRepo(), budgets: budgets);
    await openBudgets(tester);

    await tester.tap(find.text('Edit budget'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();

    expect(budgets.limitFor(thisMonth), isNull);
    expect(find.text('Set budget'), findsOneWidget);
  });

  testWidgets('an empty month says so instead of drawing a chart',
      (tester) async {
    await pumpApp(tester, repository: FakeTransactionRepository());
    await openBudgets(tester);

    expect(
        find.text('No transactions in ${Formatters.monthYear(thisMonth)}'),
        findsOneWidget);
    expect(find.text('KSh 0.00'), findsNWidgets(3)); // income, expenses, net
  });

  testWidgets('income-only month says there is no spending', (tester) async {
    await pumpApp(tester,
        repository: FakeTransactionRepository([
          tx('i', 100, thisMonth.add(const Duration(hours: 1)),
              type: TransactionType.income, category: 'gift'),
        ]));
    await openBudgets(tester);

    expect(find.text('No spending in ${Formatters.monthYear(thisMonth)}'),
        findsOneWidget);
  });
}
