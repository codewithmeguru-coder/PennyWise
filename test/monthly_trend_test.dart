import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/data/data_exception.dart';
import 'package:pennywise/data/transaction_store.dart';
import 'package:pennywise/models/custom_category.dart';
import 'package:pennywise/models/month_selection.dart';
import 'package:pennywise/models/monthly_summary.dart';
import 'package:pennywise/models/monthly_trend.dart';
import 'package:pennywise/models/transaction_category.dart';
import 'package:pennywise/models/transaction_model.dart';
import 'package:pennywise/screens/budgets_screen.dart';
import 'package:pennywise/screens/trends_screen.dart';
import 'package:pennywise/utils/formatters.dart';
import 'package:pennywise/widgets/charts/chart_style.dart';
import 'package:pennywise/widgets/monthly_overview_card.dart';

import 'fake_transaction_repository.dart';
import 'test_app.dart';

// Month-by-month trends: every month equals MonthlySummary (the Ledger's
// rules), changes are exact, the current month compares the same elapsed
// days, and categories keep their (current) names. In memory only.

var _n = 0;
TransactionModel tx(
  TransactionType type,
  double amount,
  DateTime date, {
  String category = 'food',
  double? fee,
  double? interest,
}) => TransactionModel(
  id: 'm${_n++}',
  description: '${type.label} $amount',
  amount: amount,
  type: type,
  categoryId: category,
  date: date,
  fee: fee,
  interest: interest,
  account: Account.mpesa,
  toAccount: type == TransactionType.transfer ? Account.cash : null,
);

DateTime d(int month, int day, [int year = 2026]) =>
    DateTime(year, month, day, 10);

/// Every kind of movement in [month]. Spending 300 + 10 fee + 29 fee + 2
/// interest − 100 refund = 241; income 5,000; saved 500 − 200 = 300.
List<TransactionModel> mixed(int month) => [
  tx(TransactionType.income, 5000, d(month, 1), category: 'salary'),
  tx(TransactionType.expense, 300, d(month, 2), fee: 10),
  tx(
    TransactionType.transfer,
    1000,
    d(month, 3),
    category: 'transfer',
    fee: 29,
  ),
  tx(
    TransactionType.savingsContribution,
    500,
    d(month, 4),
    category: 'savings',
  ),
  tx(
    TransactionType.savingsWithdrawal,
    200,
    d(month, 5),
    category: 'savings_withdrawal',
  ),
  tx(
    TransactionType.debtRepayment,
    200,
    d(month, 6),
    category: 'debt_repayment',
    interest: 2,
  ),
  tx(TransactionType.refund, 100, d(month, 7)),
];

MonthlyTrend build(
  List<TransactionModel> ts,
  DateTime end, {
  int range = 6,
  DateTime? today,
}) => MonthlyTrend.build(
  ts,
  end: end,
  range: range,
  today: today ?? DateTime(2026, 12, 15),
);

void main() {
  tearDown(DefaultCategories.clearCustom);

  group('figures', () {
    test('each month is exactly that month\'s MonthlySummary', () {
      final ts = [
        ...mixed(9),
        ...mixed(10),
        tx(TransactionType.expense, 700, d(10, 20), category: 'shopping'),
      ];
      final t = build(ts, DateTime(2026, 10));
      expect(t.months.map((m) => m.month), [
        DateTime(2026, 9),
        DateTime(2026, 10),
      ]);
      for (final m in t.months) {
        final s = MonthlySummary.calculate(transactions: ts, month: m.month);
        expect(m.income, s.income);
        expect(m.expenses, s.expenses);
        expect(m.net, s.net);
        expect(m.netSaved, s.netSaved);
      }
    });

    test('fees and interest count; refunds reduce their category; '
        'transfers, savings and loan principal are left out; savings are '
        'separate', () {
      final t = build(mixed(9), DateTime(2026, 9));
      final sep = t.months.single;
      expect(sep.expenses, 241);
      expect(sep.income, 5000); // not the savings withdrawal or refund
      expect(sep.net, 4759);
      expect(sep.netSaved, 300);
      final food = sep.byCategory.firstWhere((c) => c.categoryId == 'food');
      expect(food.amount, 200); // 300 − 100 refund
      // Transfers and savings never appear; the loan repayment shows only
      // its interest (2), never the principal (198).
      expect(
        sep.byCategory.map((c) => c.categoryId),
        isNot(anyOf(contains('transfer'), contains('savings'))),
      );
      expect(
        sep.byCategory
            .firstWhere((c) => c.categoryId == 'debt_repayment')
            .amount,
        2,
      );
      expect(
        sep.byCategory.firstWhere((c) => c.categoryId == 'fees').amount,
        39,
      );
    });
  });

  group('changes', () {
    test('amount and percentage; "new" from 0; down to 0; exact cents', () {
      expect(const TrendChange(1185, 1000).change, 185);
      expect(const TrendChange(1185, 1000).percent, closeTo(18.5, 1e-9));
      expect(const TrendChange(300, 0).percent, isNull);
      expect(const TrendChange(0, 250).percent, -100);
      expect(const TrendChange(0.3, 0.1).change, 0.2);
      expect(const TrendChange(-200, -100).percent, -100);
    });

    test('a full month against the whole previous month', () {
      final ts = [
        tx(TransactionType.expense, 1000, d(9, 10)),
        tx(TransactionType.expense, 500, d(9, 28)),
        tx(TransactionType.expense, 1200, d(10, 5)),
      ];
      final c = build(
        ts,
        DateTime(2026, 10),
        today: DateTime(2026, 11, 3),
      ).comparison!;
      expect(c.isPartial, isFalse);
      expect(c.expenses.previous, 1500);
      expect(c.expenses.current, 1200);
      expect(c.expenses.change, -300);
    });

    test('the current month compares the same elapsed days', () {
      final ts = [
        tx(TransactionType.expense, 1000, d(9, 10)),
        tx(TransactionType.expense, 500, d(9, 28)), // after day 27: left out
        tx(TransactionType.expense, 1200, d(10, 5)),
      ];
      final c = build(
        ts,
        DateTime(2026, 10),
        today: DateTime(2026, 10, 27, 9),
      ).comparison!;
      expect(c.isPartial, isTrue);
      expect(c.partialDay, 27);
      expect(c.previousDay, 27);
      expect(c.expenses.previous, 1000);
      expect(c.expenses.current, 1200);
    });

    test('a day the previous month lacks is capped at its last day', () {
      final ts = [
        tx(TransactionType.expense, 400, d(9, 30)),
        tx(TransactionType.expense, 100, d(10, 31)),
        tx(TransactionType.expense, 50, d(2, 28, 2027)),
        tx(TransactionType.expense, 70, d(3, 30, 2027)),
      ];
      final oct = build(
        ts,
        DateTime(2026, 10),
        today: DateTime(2026, 10, 31),
      ).comparison!;
      expect(oct.partialDay, 31);
      expect(oct.previousDay, 30);
      expect(oct.expenses.previous, 400); // all of September
      final mar = build(
        ts,
        DateTime(2027, 3),
        today: DateTime(2027, 3, 30),
      ).comparison!;
      expect(mar.previousDay, 28);
      expect(mar.expenses.previous, 50);
    });

    test('across a year: January against December', () {
      final ts = [
        tx(TransactionType.expense, 900, d(12, 15)),
        tx(TransactionType.expense, 600, d(1, 15, 2027)),
      ];
      final c = build(
        ts,
        DateTime(2027, 1),
        today: DateTime(2027, 2, 1),
      ).comparison!;
      expect(c.previousMonth, DateTime(2026, 12));
      expect(c.expenses.change, -300);
    });

    test('biggest changes: top three each way, at least KSh 50, a category '
        'in only one month included', () {
      List<TransactionModel> month(int m, Map<String, double> spend) => [
        for (final e in spend.entries)
          tx(TransactionType.expense, e.value, d(m, 10), category: e.key),
      ];
      final ts = [
        ...month(9, {
          'food': 1000,
          'transport': 500,
          'shopping': 800,
          'bills': 300,
          'health': 200,
          'education': 100,
          'housing': 60,
        }),
        ...month(10, {
          'food': 1500,
          'transport': 520,
          'shopping': 100,
          'bills': 700,
          'entertainment': 400,
          'health': 0.01,
          'education': 160,
        }),
      ];
      final c = build(
        ts,
        DateTime(2026, 10),
        today: DateTime(2026, 11, 2),
      ).comparison!;
      expect(c.increases.map((m) => m.categoryId), [
        'food',
        'bills',
        'entertainment',
      ]);
      expect(c.increases[2].amounts.percent, isNull); // new
      expect(c.decreases.map((m) => m.categoryId), [
        'shopping',
        'health',
        'housing',
      ]); // housing: 60 → 0
      expect(c.decreases[2].amounts.current, 0);
      // transport (+20) is under the noise floor; education +60 ranks 4th.
      expect(
        [...c.increases, ...c.decreases].map((m) => m.categoryId),
        isNot(contains('transport')),
      );
    });
  });

  group('range and history', () {
    test('months before history aren\'t drawn; a gap month is 0', () {
      final ts = [
        tx(TransactionType.expense, 100, d(8, 3)),
        tx(TransactionType.expense, 300, d(10, 3)),
      ];
      final t = build(
        ts,
        DateTime(2026, 10),
        range: 12,
        today: DateTime(2026, 10, 27),
      );
      expect(t.range, 12);
      expect(t.months.map((m) => m.month.month), [8, 9, 10]);
      expect(t.months[1].expenses, 0);
      expect(t.months[1].transactionCount, 0);
      expect(t.firstMonth, DateTime(2026, 8));
      expect(t.historyMonths, 3);
      expect(
        build(
          ts,
          DateTime(2026, 10),
          range: 3,
          today: DateTime(2026, 10, 27),
        ).months,
        hasLength(3),
      );
    });

    test('one month of history: nothing to compare', () {
      final t = build(
        [tx(TransactionType.expense, 10, d(10, 3))],
        DateTime(2026, 10),
        today: DateTime(2026, 10, 27),
      );
      expect(t.months, hasLength(1));
      expect(t.comparison, isNull);
      expect(t.historyMonths, 1);
    });

    test('no transactions', () {
      final t = build(const [], DateTime(2026, 10));
      expect(t.isEmpty, isTrue);
      expect(t.months, isEmpty);
      expect(t.comparison, isNull);
      expect(t.topCategories, isEmpty);
    });
  });

  group('categories', () {
    test('top five plus Other add up to each month\'s category total', () {
      final cats = [
        'food',
        'transport',
        'shopping',
        'bills',
        'health',
        'education',
        'housing',
      ];
      final ts = [
        for (var i = 0; i < cats.length; i++) ...[
          tx(
            TransactionType.expense,
            100.0 * (i + 1),
            d(9, 5),
            category: cats[i],
          ),
          tx(
            TransactionType.expense,
            50.5 * (i + 1),
            d(10, 5),
            category: cats[i],
          ),
        ],
      ];
      final t = build(ts, DateTime(2026, 10));
      expect(t.topCategories, hasLength(5));
      expect(t.topCategories.first, 'housing');
      final other = t.otherByMonth();
      for (var i = 0; i < t.months.length; i++) {
        final parts =
            t.topCategories.fold<double>(
              0,
              (s, id) => s + t.categoryByMonth(id)[i],
            ) +
            other[i];
        final total = t.months[i].byCategory.fold<double>(
          0,
          (s, c) => s + c.amount,
        );
        expect(parts, closeTo(total, 1e-9));
      }
    });

    test('a renamed custom category shows its current name in every month; '
        'a turned-off one is marked; an unknown id is "Other"', () {
      DefaultCategories.useCustom([
        const CustomCategory(
          id: 'c_petsabcdef',
          name: 'Pet care',
          type: TransactionType.expense,
        ).toCategory(),
        const CustomCategory(
          id: 'c_churchgive',
          name: 'Church',
          type: TransactionType.expense,
          active: false,
        ).toCategory(),
      ]);
      final t = build([
        tx(TransactionType.expense, 300, d(9, 5), category: 'c_petsabcdef'),
        tx(TransactionType.expense, 200, d(10, 5), category: 'c_churchgive'),
      ], DateTime(2026, 10));
      expect(t.topCategories, containsAll(['c_petsabcdef', 'c_churchgive']));
      expect(t.categoryByMonth('c_petsabcdef'), [300, 0]);
      expect(trendName('c_petsabcdef'), 'Pet care');
      expect(trendName('c_churchgive'), 'Church (off)');
      expect(trendName('c_nolongerknown'), 'Other');
    });
  });

  group('screens', () {
    final now = DateTime.now();
    final thisMonth = DateTime(now.year, now.month);
    DateTime inMonth(DateTime m, int day) => DateTime(m.year, m.month, day, 8);
    final lastMonth = DateTime(now.year, now.month - 1);

    void phone(WidgetTester tester) {
      tester.view.physicalSize = const Size(1080, 4800);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
    }

    Future<void> show(
      WidgetTester tester,
      TransactionStore store, {
      MonthSelection? month,
    }) async {
      phone(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: TrendsScreen(store: store, month: month ?? MonthSelection()),
        ),
      );
      await tester.pumpAndSettle();
    }

    List<TransactionModel> twoMonths() => [
      tx(
        TransactionType.income,
        5000,
        inMonth(lastMonth, 1),
        category: 'salary',
      ),
      tx(TransactionType.expense, 1000, inMonth(lastMonth, 1)),
      tx(
        TransactionType.expense,
        400,
        inMonth(lastMonth, 1),
        category: 'shopping',
      ),
      tx(
        TransactionType.income,
        3000,
        inMonth(thisMonth, 1),
        category: 'salary',
      ),
      tx(TransactionType.expense, 1600, inMonth(thisMonth, 1)),
    ];

    testWidgets('the current month: same-days comparison, clearly labelled', (
      tester,
    ) async {
      await show(
        tester,
        TransactionStore(FakeTransactionRepository(twoMonths())),
      );
      final month = Formatters.monthYear(thisMonth).split(' ').first;
      expect(find.textContaining('so far vs'), findsOneWidget);
      expect(find.textContaining('1–${now.day} $month'), findsOneWidget);
      expect(
        find.text('Part of the month only: not a full-month result.'),
        findsOneWidget,
      );
      expect(find.textContaining('History: 2 months'), findsOneWidget);
      expect(find.text('Income vs expenses'), findsOneWidget);
      expect(find.text('Net cash flow'), findsOneWidget);
      expect(find.text('Spending by category'), findsOneWidget);
      expect(find.text('Spending up'), findsOneWidget);
    });

    testWidgets('a past month is a full-month comparison; range chips', (
      tester,
    ) async {
      final sel = MonthSelection()..previous();
      await show(
        tester,
        TransactionStore(
          FakeTransactionRepository([
            ...twoMonths(),
            tx(
              TransactionType.expense,
              80,
              inMonth(DateTime(now.year, now.month - 2), 3),
            ),
          ]),
        ),
        month: sel,
      );
      expect(find.textContaining('so far'), findsNothing);
      expect(
        find.text(
          '${Formatters.monthYear(lastMonth)} vs '
          '${Formatters.monthYear(DateTime(now.year, now.month - 2))}',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('3 months'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Showing the 2 in this range'),
        findsOneWidget,
      );
    });

    testWidgets('tap a category to focus on it, then Show all', (tester) async {
      await show(
        tester,
        TransactionStore(FakeTransactionRepository(twoMonths())),
      );
      // The "Spending down" row for Shopping (400 last month, 0 now).
      final row = find.ancestor(
        of: find.text('Shopping').last,
        matching: find.byType(ListTile),
      );
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.text('Show all'), findsOneWidget);
      await tester.ensureVisible(find.text('Show all'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show all'));
      await tester.pumpAndSettle();
      expect(find.text('Show all'), findsNothing);
    });

    testWidgets('one month only: comparisons start later', (tester) async {
      await show(
        tester,
        TransactionStore(
          FakeTransactionRepository([
            tx(TransactionType.expense, 100, inMonth(thisMonth, 1)),
          ]),
        ),
      );
      expect(
        find.text(
          'Comparisons start once there are two months of '
          'history.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('History: 1 month,'), findsOneWidget);
    });

    testWidgets('no transactions; a load error with Retry', (tester) async {
      await show(tester, TransactionStore(FakeTransactionRepository()));
      expect(find.text('No transactions yet'), findsOneWidget);

      final repo = FakeTransactionRepository(twoMonths())
        ..loadError = const DataException('No connection.');
      await show(tester, TransactionStore(repo));
      expect(find.text('Couldn\'t load transactions'), findsOneWidget);
      repo.loadError = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Income vs expenses'), findsOneWidget);
    });

    testWidgets('a month that cost more than it earned draws below zero', (
      tester,
    ) async {
      await show(
        tester,
        TransactionStore(
          FakeTransactionRepository(
            twoMonths()
              ..add(tx(TransactionType.expense, 9000, inMonth(thisMonth, 1))),
          ),
        ),
      );
      final charts = tester.widgetList<BarChart>(find.byType(BarChart));
      expect(charts.any((c) => c.data.minY < 0), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('opens from Home\'s overview and from Budgets, on the shared '
        'month', (tester) async {
      phone(tester);
      await pumpApp(tester, repository: FakeTransactionRepository(twoMonths()));
      final overview = find.byType(MonthlyOverviewCard);
      await tester.scrollUntilVisible(
        find.descendant(of: overview, matching: find.text('Trends')),
        200,
        scrollable: find.byType(Scrollable).hitTestable().first,
      );
      await tester.tap(
        find.descendant(
          of: overview,
          matching: find.byTooltip('Previous month'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: overview, matching: find.text('Trends')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TrendsScreen), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(TrendsScreen),
          matching: find.text(Formatters.monthYear(lastMonth)),
        ),
        findsOneWidget,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.savings_outlined));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(BudgetsScreen),
          matching: find.text('Trends'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TrendsScreen), findsOneWidget);
    });
  });

  test('existing charts with no negative values are unchanged', () {
    const s = ChartSeries('A', Colors.red, [1, 2]);
    expect(s.colorFor(-1), Colors.red); // no negativeColor: same colour
    const n = ChartSeries('N', Colors.green, [1], negativeColor: Colors.red);
    expect(n.colorFor(5), Colors.green);
    expect(n.colorFor(-5), Colors.red);
  });
}
