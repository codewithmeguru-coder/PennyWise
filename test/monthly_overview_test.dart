import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/data/data_exception.dart';
import 'package:pennywise/models/budget_model.dart';
import 'package:pennywise/models/month_selection.dart';
import 'package:pennywise/models/monthly_summary.dart';
import 'package:pennywise/models/spending_trend.dart';
import 'package:pennywise/models/transaction_model.dart';
import 'package:pennywise/screens/budgets_screen.dart';
import 'package:pennywise/utils/formatters.dart';
import 'package:pennywise/widgets/balance_card.dart';
import 'package:pennywise/widgets/charts/category_donut.dart';
import 'package:pennywise/widgets/monthly_overview_card.dart';

import 'fake_auth_service.dart';
import 'fake_budget_repository.dart';
import 'fake_transaction_repository.dart';
import 'test_app.dart';

// Phase 4B: the shared month, spending over time, the category donut, and
// Home's monthly overview with Budgets' charts. All figures come from the
// existing Ledger / MonthlySummary; these tests pin what they show.

var _n = 0;
TransactionModel tx(
  TransactionType type,
  double amount,
  DateTime date, {
  String category = 'food',
  double? fee,
  double? interest,
  String? description,
}) => TransactionModel(
  id: 'x${_n++}',
  description: description ?? '${type.label} $amount',
  amount: amount,
  type: type,
  categoryId: category,
  date: date,
  fee: fee,
  interest: interest,
  account: Account.mpesa,
  toAccount: type == TransactionType.transfer ? Account.cash : null,
);

/// One month of every kind of movement. What it cost:
/// 300 + 10 fee (food) + 29 fee (withdrawal) + 2 interest − 100 refund
/// + 50 at 00:00 on the 1st = 291. Income 5,000.
List<TransactionModel> mixedMonth(DateTime month) {
  DateTime day(int d, [int h = 10, int m = 0]) =>
      DateTime(month.year, month.month, d, h, m);
  return [
    tx(TransactionType.income, 5000, day(1), category: 'salary'),
    tx(TransactionType.expense, 50, day(1, 0, 0), category: 'transport'),
    tx(TransactionType.expense, 300, day(1), fee: 10),
    // A cash withdrawal: only its fee is spending.
    tx(TransactionType.transfer, 1000, day(1), category: 'transfer', fee: 29),
    // Savings in and out: not spending, not income.
    tx(TransactionType.savingsContribution, 500, day(1), category: 'savings'),
    tx(
      TransactionType.savingsWithdrawal,
      200,
      day(1),
      category: 'savings_withdrawal',
    ),
    // Loan repayment: only the interest is spending.
    tx(
      TransactionType.debtRepayment,
      200,
      day(1),
      category: 'debt_repayment',
      interest: 2,
    ),
    // A refund comes off food, not income.
    tx(TransactionType.refund, 100, day(1)),
  ];
}

void main() {
  group('MonthSelection', () {
    test('starts on the current month and can\'t go into the future', () {
      final s = MonthSelection(clock: () => DateTime(2026, 10, 26, 15));
      expect(s.value, DateTime(2026, 10));
      expect(s.canGoForward, isFalse);
      s.next();
      expect(s.value, DateTime(2026, 10));
      s.value = DateTime(2027, 3, 4);
      expect(s.value, DateTime(2026, 10));
    });

    test('previous / next across a year', () {
      final s = MonthSelection(clock: () => DateTime(2026, 1, 5));
      s.previous();
      expect(s.value, DateTime(2025, 12));
      expect(s.canGoForward, isTrue);
      s.next();
      expect(s.value, DateTime(2026, 1));
    });

    test('never before the first month', () {
      final s = MonthSelection(clock: () => DateTime(2026, 10, 26));
      s.value = DateTime(2019, 6);
      expect(s.value, MonthSelection.first);
      expect(s.canGoBack, isFalse);
      s.previous();
      expect(s.value, MonthSelection.first);
    });

    test('any day sets that day\'s month', () {
      final s = MonthSelection(clock: () => DateTime(2026, 10, 26));
      s.value = DateTime(2026, 9, 30, 23, 59);
      expect(s.value, DateTime(2026, 9));
    });
  });

  group('month totals (existing rules)', () {
    final oct = DateTime(2026, 10);

    test('transfers, savings and loan principal are not spending; fees and '
        'interest are; refunds reduce spending, not add income', () {
      final s = MonthlySummary.calculate(
        transactions: mixedMonth(oct),
        month: oct,
      );
      expect(s.expenses, 291);
      expect(s.income, 5000);
      expect(s.net, 4709);
      final food = s.byCategory.firstWhere((c) => c.categoryId == 'food');
      expect(food.amount, 200); // 300 − 100 refund
      expect(
        s.byCategory.map((c) => c.categoryId),
        isNot(contains('transfer')),
      );
      expect(s.byCategory.map((c) => c.categoryId), isNot(contains('savings')));
    });

    test('the last minute of a month and the first of the next stay apart', () {
      final ts = [
        tx(TransactionType.expense, 700, DateTime(2026, 9, 30, 23, 59)),
        tx(TransactionType.expense, 40, DateTime(2026, 10, 1, 0, 0)),
      ];
      expect(
        MonthlySummary.calculate(
          transactions: ts,
          month: DateTime(2026, 9),
        ).expenses,
        700,
      );
      expect(
        MonthlySummary.calculate(transactions: ts, month: oct).expenses,
        40,
      );
    });
  });

  group('SpendingTrend', () {
    final oct = DateTime(2026, 10);

    test('spending through the month uses the same rules, day by day', () {
      final ts = [
        ...mixedMonth(oct), // all on the 1st: 291
        tx(TransactionType.expense, 100, DateTime(2026, 10, 3)),
        tx(TransactionType.transfer, 900, DateTime(2026, 10, 3)),
        tx(TransactionType.refund, 60, DateTime(2026, 10, 4)),
        tx(TransactionType.expense, 999, DateTime(2026, 11, 1)), // next month
      ];
      final days = SpendingTrend.cumulativeByDay(
        ts,
        oct,
        today: DateTime(2026, 12, 1),
      );
      expect(days, hasLength(31));
      expect(days.sublist(0, 5), [291, 291, 391, 331, 331]);
      expect(days.last, 331);
      expect(
        days.last,
        MonthlySummary.calculate(transactions: ts, month: oct).expenses,
      );
    });

    test('in the current month it stops at today; future months are empty', () {
      final today = DateTime(2026, 10, 26, 9);
      expect(
        SpendingTrend.cumulativeByDay(
          const [],
          DateTime(2026, 10),
          today: today,
        ),
        hasLength(26),
      );
      expect(
        SpendingTrend.cumulativeByDay(
          const [],
          DateTime(2026, 11),
          today: today,
        ),
        isEmpty,
      );
    });

    test(
      'six months, oldest first, across a year, each the month\'s total',
      () {
        final ts = [
          tx(TransactionType.expense, 10, DateTime(2025, 9, 15)),
          tx(TransactionType.expense, 20, DateTime(2025, 12, 31, 23, 59)),
          tx(TransactionType.expense, 30, DateTime(2026, 1, 1)),
          tx(TransactionType.transfer, 500, DateTime(2026, 1, 2)),
          tx(TransactionType.expense, 40, DateTime(2026, 2, 10)),
        ];
        final months = SpendingTrend.monthlyTotals(ts, DateTime(2026, 2));
        expect(months.map((m) => m.$1), [
          DateTime(2025, 9),
          DateTime(2025, 10),
          DateTime(2025, 11),
          DateTime(2025, 12),
          DateTime(2026, 1),
          DateTime(2026, 2),
        ]);
        expect(months.map((m) => m.$2), [10, 0, 0, 20, 30, 40]);
      },
    );
  });

  group('CategoryDonut.slices', () {
    List<CategorySpend> cats(List<double> amounts) {
      final total = amounts.fold(0.0, (a, b) => a + b);
      return [
        for (var i = 0; i < amounts.length; i++)
          CategorySpend(
            categoryId: 'c$i',
            amount: amounts[i],
            share: amounts[i] / total,
          ),
      ];
    }

    test('top five plus Other add up to the whole', () {
      final slices = CategoryDonut.slices(
        cats([500, 400, 300, 200, 100, 50.25, 25.10]),
      );
      expect(slices, hasLength(6));
      expect(slices.last.categoryId, isNull);
      expect(slices.last.label, 'Other');
      expect(slices.last.amount, 75.35);
      expect(slices.fold(0.0, (s, x) => s + x.amount), closeTo(1575.35, 1e-9));
      expect(slices.fold(0.0, (s, x) => s + x.share), closeTo(1, 1e-9));
    });

    test('one category over five is shown as itself, not "Other"', () {
      final slices = CategoryDonut.slices(cats([6, 5, 4, 3, 2, 1]));
      expect(slices, hasLength(6));
      expect(slices.every((s) => s.categoryId != null), isTrue);
    });

    test('a refund bigger than its category leaves it out of the chart', () {
      final oct = DateTime(2026, 10);
      final s = MonthlySummary.calculate(
        transactions: [
          tx(TransactionType.expense, 100, DateTime(2026, 10, 2)),
          tx(TransactionType.refund, 150, DateTime(2026, 10, 3)),
          tx(
            TransactionType.expense,
            80,
            DateTime(2026, 10, 3),
            category: 'transport',
          ),
        ],
        month: oct,
      );
      final slices = CategoryDonut.slices(s.byCategory);
      expect(slices.map((x) => x.categoryId), ['transport']);
      expect(slices.single.amount, 80);
    });
  });

  group('screens', () {
    final now = DateTime.now();
    final thisMonth = DateTime(now.year, now.month);
    final lastMonth = DateTime(now.year, now.month - 1);

    void phone(WidgetTester tester) {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
    }

    final overview = find.byType(MonthlyOverviewCard);
    Finder inOverview(Finder f) => find.descendant(of: overview, matching: f);
    String? headerDate(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const Key('home-header-date'))).data;
    Finder inBudgets(Finder f) =>
        find.descendant(of: find.byType(BudgetsScreen), matching: f);

    /// Scrolls Home until the overview's month row is on screen.
    Future<void> showOverview(WidgetTester tester) async {
      final prev = inOverview(find.byTooltip('Previous month'));
      await tester.scrollUntilVisible(
        prev,
        100,
        scrollable: find.byType(Scrollable).hitTestable().first,
      );
      await tester.ensureVisible(inOverview(find.text('Monthly overview')));
      await tester.pumpAndSettle();
    }

    List<TransactionModel> data() => [
      ...mixedMonth(thisMonth),
      tx(
        TransactionType.expense,
        700,
        DateTime(thisMonth.year, thisMonth.month, 0, 23, 59), // last month
        category: 'shopping',
      ),
    ];

    testWidgets('Home: this month\'s figures, budget left and categories', (
      tester,
    ) async {
      phone(tester);
      await pumpApp(
        tester,
        repository: FakeTransactionRepository(data()),
        budgets: FakeBudgetRepository([
          BudgetModel(month: thisMonth, limit: 1000),
        ]),
      );
      await showOverview(tester);

      expect(
        inOverview(find.text(Formatters.monthYear(thisMonth))),
        findsOneWidget,
      );
      expect(inOverview(find.text('KSh 5,000.00')), findsOneWidget);
      expect(inOverview(find.text('KSh 291.00')), findsOneWidget);
      expect(inOverview(find.text('+KSh 4,709.00')), findsOneWidget);
      expect(
        inOverview(find.text('KSh 709.00 left of KSh 1,000.00 · 29% used')),
        findsOneWidget,
      );
      expect(inOverview(find.byType(CategoryDonut)), findsOneWidget);
      // What Expenses means: fees in; transfers, savings, repayments out.
      expect(
        inOverview(
          find.text(
            'Includes fees. Transfers, savings and loan repayments aren\'t '
            'counted.',
          ),
        ),
        findsOneWidget,
      );
      expect(headerDate(tester), Formatters.fullDate(DateTime.now()));
      // Can't go past the current month.
      final next = tester.widget<IconButton>(
        inOverview(
          find.widgetWithIcon(IconButton, Icons.chevron_right_rounded),
        ),
      );
      expect(next.onPressed, isNull);
    });

    testWidgets('the balance card no longer shows the month\'s figures', (
      tester,
    ) async {
      phone(tester);
      await pumpApp(tester, repository: FakeTransactionRepository(data()));
      expect(
        find.descendant(
          of: find.byType(BalanceCard),
          matching: find.text('Income'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(BalanceCard),
          matching: find.text('Expenses'),
        ),
        findsNothing,
      );
      expect(find.text('Available balance'), findsOneWidget);
    });

    testWidgets('previous month on Home recalculates, and Budgets follows', (
      tester,
    ) async {
      phone(tester);
      await pumpApp(tester, repository: FakeTransactionRepository(data()));
      await showOverview(tester);

      expect(headerDate(tester), Formatters.fullDate(DateTime.now()));
      await tester.tap(inOverview(find.byTooltip('Previous month')));
      await tester.pumpAndSettle();
      expect(
        inOverview(find.text(Formatters.monthYear(lastMonth))),
        findsOneWidget,
      );
      // The header keeps today's date; the overview names the month.
      expect(headerDate(tester), Formatters.fullDate(DateTime.now()));
      expect(inOverview(find.text('KSh 700.00')), findsWidgets);
      expect(inOverview(find.text('KSh 0.00')), findsOneWidget); // income
      expect(
        inOverview(
          find.text('No budget for ${Formatters.monthYear(lastMonth)}'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byIcon(Icons.savings_outlined));
      await tester.pumpAndSettle();
      expect(
        inBudgets(find.text(Formatters.monthYear(lastMonth))),
        findsOneWidget,
      );
      expect(inBudgets(find.text('KSh 700.00')), findsWidgets);

      // And back again from Budgets: Home follows.
      await tester.tap(inBudgets(find.byTooltip('Next month')));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.home_outlined));
      await tester.pumpAndSettle();
      expect(
        inOverview(find.text(Formatters.monthYear(thisMonth))),
        findsOneWidget,
      );
      expect(headerDate(tester), Formatters.fullDate(DateTime.now()));
    });

    testWidgets('an empty month and a month with only income say so', (
      tester,
    ) async {
      phone(tester);
      await pumpApp(
        tester,
        repository: FakeTransactionRepository([
          tx(
            TransactionType.income,
            900,
            DateTime(now.year, now.month, 1, 9),
            category: 'salary',
          ),
        ]),
      );
      await showOverview(tester);
      expect(
        inOverview(
          find.text('No spending in ${Formatters.monthYear(thisMonth)}'),
        ),
        findsOneWidget,
      );
      await tester.tap(inOverview(find.byTooltip('Previous month')));
      await tester.pumpAndSettle();
      expect(
        inOverview(
          find.text('No transactions in ${Formatters.monthYear(lastMonth)}'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('switching profile shows the new profile\'s figures, '
        'never the previous one\'s', (tester) async {
      // The login screen is shown at the test's default size (its test
      // font is wider than a phone's); the overview at phone size.
      final auth = FakeAuthService();
      final byUser = {
        'u-a@example.com': FakeTransactionRepository([
          tx(TransactionType.expense, 300, DateTime(thisMonth.year,
              thisMonth.month, 1, 9)),
        ]),
        'u-b@example.com': FakeTransactionRepository([
          tx(TransactionType.expense, 45, DateTime(thisMonth.year,
              thisMonth.month, 1, 9)),
        ]),
      };
      await pumpApp(tester, auth: auth, repositoryForUser: (u) => byUser[u]!);
      await auth.signIn(email: 'a@example.com', password: 'x');
      await tester.pumpAndSettle();
      phone(tester);
      await tester.pumpAndSettle();
      await showOverview(tester);
      expect(inOverview(find.text('KSh 300.00')), findsWidgets);

      tester.view.reset();
      await auth.signOut();
      await tester.pumpAndSettle();
      await auth.signIn(email: 'b@example.com', password: 'x');
      await tester.pumpAndSettle();
      phone(tester);
      await tester.pumpAndSettle();
      await showOverview(tester);
      expect(inOverview(find.text('KSh 45.00')), findsWidgets);
      expect(inOverview(find.text('KSh 300.00')), findsNothing);
      // A new profile starts on the current month.
      expect(headerDate(tester), Formatters.fullDate(DateTime.now()));
    });

    testWidgets('a load error in the overview offers Retry', (tester) async {
      phone(tester);
      final repo = FakeTransactionRepository(data())
        ..loadError = const DataException('No connection.');
      await pumpApp(tester, repository: repo);
      await showOverview(tester);
      expect(inOverview(find.text('Retry')), findsOneWidget);
      repo.loadError = null;
      await tester.tap(inOverview(find.text('Retry')));
      await tester.pumpAndSettle();
      expect(inOverview(find.text('KSh 291.00')), findsOneWidget);
    });

    testWidgets('Budgets: spending vs budget and the last 6 months', (
      tester,
    ) async {
      phone(tester);
      await pumpApp(
        tester,
        repository: FakeTransactionRepository(data()),
        budgets: FakeBudgetRepository([
          BudgetModel(month: thisMonth, limit: 1000),
        ]),
      );
      await tester.tap(find.byIcon(Icons.savings_outlined));
      await tester.pumpAndSettle();
      final list = inBudgets(find.byType(Scrollable)).first;
      await tester.scrollUntilVisible(
        inBudgets(find.text('Last 6 months')),
        300,
        scrollable: list,
      );
      expect(inBudgets(find.text('Spending vs budget')), findsOneWidget);

      // Without a budget the chart is still drawn, titled for spending only.
      await tester.drag(list, const Offset(0, 3000));
      await tester.pumpAndSettle();
      await tester.tap(inBudgets(find.byTooltip('Previous month')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        inBudgets(find.text('Last 6 months')),
        300,
        scrollable: list,
      );
      expect(inBudgets(find.text('Spending this month')), findsOneWidget);
    });
  });
}
