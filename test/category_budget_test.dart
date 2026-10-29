import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/data/data_exception.dart';
import 'package:pennywise/models/budget_model.dart';
import 'package:pennywise/models/category_budget.dart';
import 'package:pennywise/models/monthly_summary.dart';
import 'package:pennywise/models/transaction_model.dart';
import 'package:pennywise/screens/budgets_screen.dart';
import 'package:pennywise/widgets/monthly_overview_card.dart';

import 'fake_budget_repository.dart';
import 'fake_category_budget_repository.dart';
import 'fake_transaction_repository.dart';
import 'test_app.dart';

// Per-category monthly limits: the model, how they compare with spending
// (which stays the Ledger's, unchanged), and the Budgets / Home screens.
// In memory only: no Firestore.

var _n = 0;
TransactionModel tx(
  TransactionType type,
  double amount,
  DateTime date, {
  String category = 'food',
  double? fee,
  String? accountId,
  String? toAccountId,
}) => TransactionModel(
  id: 'c${_n++}',
  description: '${type.label} $amount',
  amount: amount,
  type: type,
  categoryId: category,
  date: date,
  fee: fee,
  account: Account.mpesa,
  toAccount: type == TransactionType.transfer ? Account.cash : null,
  accountId: accountId,
  toAccountId: toAccountId,
);

final oct = DateTime(2026, 10);
DateTime d(int day) => DateTime(2026, 10, day, 10);

MonthlySummary summaryOf(List<TransactionModel> ts, {double? budget}) =>
    MonthlySummary.calculate(transactions: ts, month: oct, budget: budget);

void main() {
  group('CategoryBudget', () {
    test('one document id per category per month', () {
      expect(
        CategoryBudget.idFor(DateTime(2026, 10, 26), 'food'),
        '2026-10_food',
      );
      expect(
        CategoryBudget(
          month: DateTime(2026, 1, 31),
          categoryId: 'fees',
          limit: 5,
        ).id,
        '2026-01_fees',
      );
    });

    test('only expense categories can have a limit', () {
      expect(CategoryBudget.canHaveLimit('food'), isTrue);
      expect(CategoryBudget.canHaveLimit('fees'), isTrue);
      expect(CategoryBudget.canHaveLimit('other_expense'), isTrue);
      expect(CategoryBudget.canHaveLimit('salary'), isFalse); // income
      expect(CategoryBudget.canHaveLimit('uncategorized'), isFalse);
      expect(CategoryBudget.canHaveLimit('cash_withdrawal'), isFalse);
      expect(CategoryBudget.canHaveLimit('transfer'), isFalse);
      expect(CategoryBudget.canHaveLimit('no_such_category'), isFalse);
      expect(
        CategoryBudget.budgetable.every(
          (c) => c.type == TransactionType.expense,
        ),
        isTrue,
      );
      expect(
        CategoryBudget.budgetable.every(
          (c) => CategoryBudget.validId.hasMatch(c.id),
        ),
        isTrue,
      );
    });

    test('copying last month adds only categories with no limit yet', () {
      final add = CategoryBudget.toCopy(
        {'food': 5000, 'transport': 2000, 'salary': 9},
        {'food': 4000},
      );
      expect(add, {'transport': 2000}); // food kept, salary not budgetable
      expect(CategoryBudget.toCopy({}, {'food': 1}), isEmpty);
    });
  });

  group('CategoryBudgetSummary', () {
    test('left, over, and near the limit at exactly 80%', () {
      final s = summaryOf([
        tx(TransactionType.expense, 300, d(2)),
        tx(TransactionType.expense, 1200, d(3), category: 'transport'),
        tx(TransactionType.expense, 800, d(4), category: 'shopping'),
      ]);
      final cats = CategoryBudgetSummary.of(s, {
        'food': 1000,
        'transport': 1000,
        'shopping': 1000,
      });
      final row = {for (final r in cats.rows) r.categoryId: r};
      expect(row['food']!.remaining, 700);
      expect(row['food']!.status, BudgetStatus.onTrack);
      expect(row['transport']!.remaining, -200);
      expect(row['transport']!.status, BudgetStatus.over);
      expect(row['shopping']!.status, BudgetStatus.nearLimit);
      expect(cats.overCount, 1);
      expect(cats.nearCount, 1);
      // Over first, then near, then the rest.
      expect(cats.rows.map((r) => r.categoryId), [
        'transport',
        'shopping',
        'food',
      ]);
    });

    test('spending exactly at the limit is not over', () {
      final cats = CategoryBudgetSummary.of(
        summaryOf([tx(TransactionType.expense, 500, d(2))]),
        {'food': 500},
      );
      expect(cats.rows.single.status, BudgetStatus.nearLimit);
      expect(cats.rows.single.remaining, 0);
    });

    test('a category without a limit has no status; a limit with no '
        'spending shows KSh 0', () {
      final cats = CategoryBudgetSummary.of(
        summaryOf([tx(TransactionType.expense, 300, d(2))]),
        {'health': 2000},
      );
      final row = {for (final r in cats.rows) r.categoryId: r};
      expect(row['food']!.hasLimit, isFalse);
      expect(row['food']!.status, isNull);
      expect(row['health']!.spent, 0);
      expect(row['health']!.remaining, 2000);
      expect(row['health']!.status, BudgetStatus.onTrack);
    });

    test('a refund bigger than its purchases counts as nothing spent', () {
      final cats = CategoryBudgetSummary.of(
        summaryOf([
          tx(TransactionType.expense, 100, d(2)),
          tx(TransactionType.refund, 150, d(3)),
        ]),
        {'food': 1000},
      );
      expect(cats.rows.single.spent, 0);
      expect(cats.rows.single.remaining, 1000);
    });

    test('fees (M-Pesa charges and Fuliza access fees) count under '
        'Transaction fees; transfers and savings count nowhere', () {
      final s = summaryOf([
        tx(TransactionType.expense, 300, d(2), fee: 7),
        // A Fuliza loan: a transfer whose access fee is spending.
        tx(
          TransactionType.transfer,
          100,
          d(2),
          category: 'transfer',
          fee: 1,
          accountId: 'fuliza-sim1',
          toAccountId: 'mpesa-sim1',
        ),
        tx(TransactionType.transfer, 1000, d(3), category: 'transfer', fee: 29),
        tx(TransactionType.savingsContribution, 500, d(4), category: 'savings'),
      ]);
      final cats = CategoryBudgetSummary.of(s, {
        'fees': 30,
        'food': 1000,
        'transfer': 10,
        'savings': 10,
      });
      final row = {for (final r in cats.rows) r.categoryId: r};
      expect(row['fees']!.spent, 37);
      expect(row['fees']!.status, BudgetStatus.over);
      expect(row['food']!.spent, 300);
      // Even a limit saved on them never sees transfers or savings.
      expect(row['transfer']!.spent, 0);
      expect(row['savings']!.spent, 0);
    });

    test('the month\'s overall figures are the same with or without '
        'category limits', () {
      final ts = [
        tx(TransactionType.income, 5000, d(1), category: 'salary'),
        tx(TransactionType.expense, 300, d(2), fee: 10),
        tx(TransactionType.refund, 50, d(3)),
        tx(TransactionType.expense, 900, d(4), category: 'transport'),
      ];
      final before = summaryOf(ts, budget: 1000);
      CategoryBudgetSummary.of(before, {'food': 10, 'transport': 10});
      final after = summaryOf(ts, budget: 1000);
      expect(after.expenses, before.expenses);
      expect(after.expenses, 1160);
      expect(after.remaining, before.remaining);
      expect(after.status, before.status);
      expect(
        after.byCategory.map((c) => '${c.categoryId}=${c.amount}'),
        before.byCategory.map((c) => '${c.categoryId}=${c.amount}'),
      );
    });

    test('a warning only when limits add up to more than the overall '
        'budget', () {
      final s = summaryOf([], budget: 3000);
      expect(
        CategoryBudgetSummary.of(s, {
          'food': 2000,
          'transport': 1000,
        }).exceedsOverall,
        isFalse,
      );
      final over = CategoryBudgetSummary.of(s, {
        'food': 2000,
        'transport': 1000.01,
      });
      expect(over.exceedsOverall, isTrue);
      expect(over.totalLimits, 3000.01);
      expect(
        CategoryBudgetSummary.of(summaryOf([]), {'food': 99999}).exceedsOverall,
        isFalse, // no overall budget
      );
    });

    test('limits belong to their month only', () async {
      final repo = FakeCategoryBudgetRepository([
        CategoryBudget(
          month: DateTime(2026, 9),
          categoryId: 'food',
          limit: 100,
        ),
        CategoryBudget(month: oct, categoryId: 'transport', limit: 200),
      ]);
      expect(await repo.watchMonth(DateTime(2026, 9)).first, {'food': 100});
      expect(await repo.watchMonth(oct).first, {'transport': 200});
      expect(await repo.watchMonth(DateTime(2026, 11)).first, isEmpty);
    });
  });

  group('screens', () {
    final now = DateTime.now();
    final thisMonth = DateTime(now.year, now.month);
    final lastMonth = DateTime(now.year, now.month - 1);
    DateTime day1([int h = 10]) => DateTime(now.year, now.month, 1, h);

    void phone(WidgetTester tester) {
      tester.view.physicalSize = const Size(1080, 4000);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
    }

    Finder inBudgets(Finder f) =>
        find.descendant(of: find.byType(BudgetsScreen), matching: f);

    List<TransactionModel> spending() => [
      tx(TransactionType.expense, 600, day1()),
      tx(TransactionType.expense, 400, day1(), category: 'transport'),
    ];

    Future<void> openBudgets(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.savings_outlined));
      await tester.pumpAndSettle();
    }

    Future<void> enterLimit(WidgetTester tester, String amount) async {
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Monthly limit'),
        amount,
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
    }

    testWidgets('set a limit from a row, then change and remove it', (
      tester,
    ) async {
      phone(tester);
      final limits = FakeCategoryBudgetRepository();
      await pumpApp(
        tester,
        repository: FakeTransactionRepository(spending()),
        categoryBudgets: limits,
      );
      await openBudgets(tester);

      // Without limits, rows look as before, with "Set limit".
      expect(inBudgets(find.text('60%')), findsOneWidget);
      expect(inBudgets(find.text('Set limit')), findsNWidgets(2));

      await tester.tap(inBudgets(find.text('Food')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Food limit for'), findsOneWidget);
      await enterLimit(tester, '1000');
      expect(limits.limitFor(thisMonth, 'food'), 1000);
      expect(
        inBudgets(find.text('KSh 400.00 left of KSh 1,000.00 · 60% used')),
        findsOneWidget,
      );

      await tester.tap(inBudgets(find.text('Food')));
      await tester.pumpAndSettle();
      await enterLimit(tester, '500');
      expect(limits.limitFor(thisMonth, 'food'), 500);
      expect(
        inBudgets(find.text('Over budget: KSh 100.00 over the KSh 500.00 limit · 120% used')),
        findsOneWidget,
      );

      await tester.tap(inBudgets(find.text('Food')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(limits.limitFor(thisMonth, 'food'), isNull);
      expect(
        limits.writes.last,
        'delete ${CategoryBudget.idFor(thisMonth, 'food')}',
      );
      expect(inBudgets(find.textContaining('over the')), findsNothing);
    });

    testWidgets('the limit dialog validates the amount', (tester) async {
      phone(tester);
      final limits = FakeCategoryBudgetRepository();
      await pumpApp(
        tester,
        repository: FakeTransactionRepository(spending()),
        categoryBudgets: limits,
      );
      await openBudgets(tester);
      await tester.tap(inBudgets(find.text('Food')));
      await tester.pumpAndSettle();
      await enterLimit(tester, '0');
      expect(find.text('Amount must be greater than 0'), findsOneWidget);
      expect(limits.writes, isEmpty);
    });

    testWidgets('add a limit for a category with no spending yet', (
      tester,
    ) async {
      phone(tester);
      final limits = FakeCategoryBudgetRepository();
      await pumpApp(
        tester,
        repository: FakeTransactionRepository(spending()),
        categoryBudgets: limits,
      );
      await openBudgets(tester);
      await tester.tap(inBudgets(find.text('Add a limit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Healthcare').last);
      await tester.pumpAndSettle();
      await enterLimit(tester, '2000');
      expect(limits.limitFor(thisMonth, 'health'), 2000);
      expect(inBudgets(find.text('Healthcare')), findsOneWidget);
      expect(
        inBudgets(find.text('KSh 2,000.00 left of KSh 2,000.00 · 0% used')),
        findsOneWidget,
      );
    });

    testWidgets('over-limit categories come first, with a warning when '
        'limits exceed the overall budget', (tester) async {
      phone(tester);
      await pumpApp(
        tester,
        repository: FakeTransactionRepository(spending()),
        budgets: FakeBudgetRepository([
          BudgetModel(month: thisMonth, limit: 1500),
        ]),
        categoryBudgets: FakeCategoryBudgetRepository([
          CategoryBudget(month: thisMonth, categoryId: 'food', limit: 1000),
          CategoryBudget(month: thisMonth, categoryId: 'transport', limit: 300),
          CategoryBudget(month: thisMonth, categoryId: 'health', limit: 500),
        ]),
      );
      await openBudgets(tester);
      expect(
        inBudgets(find.text('Over budget: KSh 100.00 over the KSh 300.00 limit · 133% used')),
        findsOneWidget,
      );
      final transportY = tester
          .getTopLeft(inBudgets(find.text('Transport')))
          .dy;
      final foodY = tester.getTopLeft(inBudgets(find.text('Food'))).dy;
      expect(transportY, lessThan(foodY));
      expect(
        inBudgets(
          find.textContaining(
            'Category limits add up to '
            'KSh 1,800.00, more than the overall budget of KSh 1,500.00',
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('copy last month: confirms, adds only missing limits, keeps '
        'this month\'s; Cancel changes nothing', (tester) async {
      phone(tester);
      final limits = FakeCategoryBudgetRepository([
        CategoryBudget(month: lastMonth, categoryId: 'food', limit: 900),
        CategoryBudget(month: lastMonth, categoryId: 'transport', limit: 300),
        CategoryBudget(month: thisMonth, categoryId: 'food', limit: 1200),
      ]);
      await pumpApp(
        tester,
        repository: FakeTransactionRepository(spending()),
        categoryBudgets: limits,
      );
      await openBudgets(tester);

      await tester.tap(inBudgets(find.text('Copy last month\'s limits')));
      await tester.pumpAndSettle();
      expect(find.textContaining('This adds 1 category limit'), findsOneWidget);
      expect(find.text('• Transport: KSh 300.00'), findsOneWidget);
      expect(
        find.textContaining('1 category that already has a limit'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(limits.writes, isEmpty);

      await tester.tap(inBudgets(find.text('Copy last month\'s limits')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      expect(limits.limitFor(thisMonth, 'transport'), 300);
      expect(limits.limitFor(thisMonth, 'food'), 1200); // kept
      expect(limits.limitFor(lastMonth, 'food'), 900); // unchanged
      expect(limits.writes, [
        'save ${CategoryBudget.idFor(thisMonth, 'transport')} 300.0',
      ]);
    });

    testWidgets('copy with nothing to copy says so and writes nothing', (
      tester,
    ) async {
      phone(tester);
      final limits = FakeCategoryBudgetRepository();
      await pumpApp(
        tester,
        repository: FakeTransactionRepository(spending()),
        categoryBudgets: limits,
      );
      await openBudgets(tester);
      await tester.tap(inBudgets(find.text('Copy last month\'s limits')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('has no category limits to copy'),
        findsOneWidget,
      );
      expect(limits.writes, isEmpty);
    });

    testWidgets('limits that can\'t load: spending still shows, editing is '
        'off', (tester) async {
      phone(tester);
      final limits = FakeCategoryBudgetRepository()
        ..loadError = const DataException('No connection.');
      await pumpApp(
        tester,
        repository: FakeTransactionRepository(spending()),
        categoryBudgets: limits,
      );
      await openBudgets(tester);
      expect(
        inBudgets(find.text('Couldn\'t load category limits. No connection.')),
        findsOneWidget,
      );
      expect(inBudgets(find.text('Food')), findsOneWidget);
      expect(inBudgets(find.text('Set limit')), findsNothing);
      final add = tester.widget<TextButton>(
        find.ancestor(
          of: inBudgets(find.text('Add a limit')),
          matching: find.byWidgetPredicate((w) => w is TextButton),
        ),
      );
      expect(add.onPressed, isNull);
    });

    testWidgets('a save that fails says so', (tester) async {
      phone(tester);
      final limits = FakeCategoryBudgetRepository()
        ..writeError = const DataException('Couldn\'t save. Try again.');
      await pumpApp(
        tester,
        repository: FakeTransactionRepository(spending()),
        categoryBudgets: limits,
      );
      await openBudgets(tester);
      await tester.tap(inBudgets(find.text('Food')));
      await tester.pumpAndSettle();
      await enterLimit(tester, '1000');
      expect(find.text('Couldn\'t save. Try again.'), findsOneWidget);
      expect(limits.limitFor(thisMonth, 'food'), isNull);
    });

    testWidgets('Home mentions an over-limit category and opens Budgets on '
        'the same month', (tester) async {
      phone(tester);
      await pumpApp(
        tester,
        repository: FakeTransactionRepository(spending()),
        categoryBudgets: FakeCategoryBudgetRepository([
          CategoryBudget(month: thisMonth, categoryId: 'food', limit: 500),
          CategoryBudget(month: thisMonth, categoryId: 'transport', limit: 450),
        ]),
      );
      final overview = find.byType(MonthlyOverviewCard);
      await tester.scrollUntilVisible(
        find.descendant(
          of: overview,
          matching: find.text('Food over its limit · Transport near its limit'),
        ),
        200,
        scrollable: find.byType(Scrollable).hitTestable().first,
      );
      await tester.tap(
        find.descendant(
          of: overview,
          matching: find.text('Food over its limit · Transport near its limit'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        inBudgets(find.text('Over budget: KSh 100.00 over the KSh 500.00 limit · 120% used')),
        findsOneWidget,
      );
    });

    testWidgets('Home says nothing about limits when all are on track', (
      tester,
    ) async {
      phone(tester);
      await pumpApp(
        tester,
        repository: FakeTransactionRepository(spending()),
        categoryBudgets: FakeCategoryBudgetRepository([
          CategoryBudget(month: thisMonth, categoryId: 'food', limit: 5000),
        ]),
      );
      // The overview is on screen, so "nothing" is a real check.
      await tester.scrollUntilVisible(
        find.text('Monthly overview'),
        200,
        scrollable: find.byType(Scrollable).hitTestable().first,
      );
      expect(find.text('Monthly overview'), findsOneWidget);
      expect(find.textContaining('its limit'), findsNothing);
      expect(find.textContaining('their limit'), findsNothing);
    });
  });
}
