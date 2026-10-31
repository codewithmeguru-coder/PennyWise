import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/data/data_exception.dart';
import 'package:pennywise/data/transaction_store.dart';
import 'package:pennywise/models/budget_model.dart';
import 'package:pennywise/models/month_selection.dart';
import 'package:pennywise/models/monthly_summary.dart';
import 'package:pennywise/models/spend_period.dart';
import 'package:pennywise/models/transaction_model.dart';
import 'package:pennywise/utils/formatters.dart';
import 'package:pennywise/widgets/monthly_overview_card.dart';

import 'fake_auth_service.dart';
import 'fake_budget_repository.dart';
import 'fake_transaction_repository.dart';
import 'test_app.dart';

// Home: the full date in the header, a compact greeting, and the overview's
// Day | Week | Month selector. Codes and amounts are made up.

var _n = 0;
TransactionModel tx(
  TransactionType type,
  double amount,
  DateTime date, {
  String category = 'food',
  double? fee,
  String? id,
  String? reference,
}) => TransactionModel(
  id: id ?? 'p${_n++}',
  description: '${type.label} $amount',
  amount: amount,
  type: type,
  categoryId: category,
  date: date,
  fee: fee,
  reference: reference,
  account: Account.mpesa,
  toAccount: type == TransactionType.transfer ? Account.cash : null,
);

/// Saturday 31 October 2026, midday, on the phone.
final saturday = DateTime(2026, 10, 31, 12);

/// One week of activity (Mon 26 Oct – Sun 1 Nov 2026) and its edges.
List<TransactionModel> week() => [
  // Saturday 31 Oct (today).
  tx(TransactionType.expense, 200, DateTime(2026, 10, 31, 8)),
  tx(TransactionType.income, 1000, DateTime(2026, 10, 31, 9)),
  tx(TransactionType.transfer, 500, DateTime(2026, 10, 31, 10)), // a move
  tx(TransactionType.savingsContribution, 300, DateTime(2026, 10, 31, 11),
      category: 'savings'),
  // A Fuliza loan (principal is a move; its fee is spending) and the payment
  // it completed, which shares its code.
  tx(TransactionType.transfer, 100, DateTime(2026, 10, 31, 11, 30),
      category: 'transfer', fee: 1, id: 'mpesa_UZ1_FULIZA', reference: 'UZ1'),
  tx(TransactionType.expense, 100, DateTime(2026, 10, 31, 11, 30),
      category: 'transport', id: 'mpesa_UZ1', reference: 'UZ1'),
  tx(TransactionType.refund, 50, DateTime(2026, 10, 31, 23, 59)),
  // Monday 26 Oct at midnight: first moment of the week.
  tx(TransactionType.expense, 40, DateTime(2026, 10, 26),
      category: 'transport'),
  // Thursday 29 Oct.
  tx(TransactionType.debtRepayment, 101, DateTime(2026, 10, 29, 9),
      category: 'debt_repayment'),
  // Sunday 25 Oct 23:59: last week. September: another month.
  tx(TransactionType.expense, 999, DateTime(2026, 10, 25, 23, 59)),
  tx(TransactionType.expense, 777, DateTime(2026, 9, 30, 12)),
];

void main() {
  group('dates', () {
    test('the full date has the right weekday', () {
      expect(Formatters.fullDate(saturday), 'Saturday, 31 October 2026');
      expect(Formatters.fullDate(DateTime(2026, 11, 2)),
          'Monday, 2 November 2026');
      expect(Formatters.fullDate(DateTime(2024, 2, 29)),
          'Thursday, 29 February 2024');
      expect(Formatters.fullDate(DateTime(2027, 1, 3)), 'Sunday, 3 January 2027');
    });

    test('a week runs Monday 00:00 to the end of Sunday', () {
      final w = PeriodRange.containing(SpendPeriod.week, saturday);
      expect(w.start, DateTime(2026, 10, 26));
      expect(w.end, DateTime(2026, 11, 2));
      expect(w.label, 'Mon 26 Oct – Sun 1 Nov 2026');
      expect(w.contains(DateTime(2026, 11, 1, 23, 59, 59)), isTrue);
      expect(w.contains(DateTime(2026, 11, 2)), isFalse);
      expect(w.contains(DateTime(2026, 10, 25, 23, 59)), isFalse);
      // Sunday belongs to the week that started on Monday.
      expect(PeriodRange.containing(SpendPeriod.week, DateTime(2026, 11, 1)), w);
      expect(PeriodRange.containing(SpendPeriod.week, DateTime(2026, 10, 26)),
          w);
      expect(w.previous.start, DateTime(2026, 10, 19));
      expect(w.next.start, DateTime(2026, 11, 2));
    });

    test('a week across the new year names both years', () {
      final w = PeriodRange.containing(SpendPeriod.week, DateTime(2026, 12, 31));
      expect(w.label, 'Mon 28 Dec 2026 – Sun 3 Jan 2027');
    });

    test('a day is midnight to midnight', () {
      final d = PeriodRange.containing(SpendPeriod.day, saturday);
      expect(d.label, 'Saturday, 31 October 2026');
      expect(d.contains(DateTime(2026, 10, 31, 23, 59, 59)), isTrue);
      expect(d.contains(DateTime(2026, 11, 1)), isFalse);
      expect(d.previous.label, 'Friday, 30 October 2026');
      expect(d.next.label, 'Sunday, 1 November 2026');
      expect(d.currentLabel(saturday), 'Today');
      expect(d.previous.currentLabel(saturday), isNull);
    });
  });

  group('totals by the usual rules', () {
    MonthlySummary over(PeriodRange r) => MonthlySummary.between(
      transactions: week(),
      start: r.start,
      end: r.end,
    );

    test('a day: moves, savings and loans aren\'t spending; the loan fee '
        'counts once; a refund comes off', () {
      final s = over(PeriodRange.containing(SpendPeriod.day, saturday));
      expect(s.income, 1000);
      // 200 + 100 payment + 1 Fuliza fee − 50 refund.
      expect(s.expenses, 251);
      expect(s.net, 749);
      final byId = {for (final c in s.byCategory) c.categoryId: c.amount};
      expect(byId['fees'], 1);
      expect(byId['transport'], 100);
      expect(byId.containsKey('transfer'), isFalse);
      expect(byId.containsKey('savings'), isFalse);
    });

    test('a week adds Monday and leaves out last Sunday', () {
      final s = over(PeriodRange.containing(SpendPeriod.week, saturday));
      expect(s.expenses, 291); // the day's 251 + Monday's 40
      expect(s.income, 1000);
    });

    test('the month is the same as before', () {
      final m = over(PeriodRange.containing(SpendPeriod.month, saturday));
      final old = MonthlySummary.calculate(
        transactions: week(),
        month: DateTime(2026, 10),
      );
      expect(m.expenses, old.expenses);
      expect(m.expenses, 1290); // + Sunday 25 Oct's 999
      expect(m.income, old.income);
    });
  });

  group('the overview', () {
    final card = find.byType(MonthlyOverviewCard);
    Finder inCard(Finder f) => find.descendant(of: card, matching: f);
    String rangeText(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const Key('overview-range'))).data!;

    Future<MonthSelection> show(
      WidgetTester tester, {
      TransactionStore? store,
      FakeBudgetRepository? budgets,
      bool settle = true,
    }) async {
      tester.view.physicalSize = const Size(1080, 4000);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final month = MonthSelection(clock: () => saturday);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MonthlyOverviewCard(
                store: store ?? TransactionStore(FakeTransactionRepository(week())),
                budgetRepository: budgets ?? FakeBudgetRepository(),
                month: month,
                clock: () => saturday,
              ),
            ),
          ),
        ),
      );
      settle ? await tester.pumpAndSettle() : await tester.pump();
      return month;
    }

    Future<void> pick(WidgetTester tester, SpendPeriod p) async {
      await tester.tap(find.byKey(Key('period-${p.name}')));
      await tester.pumpAndSettle();
    }

    testWidgets('starts on Month, as before, with the budget', (tester) async {
      await show(
        tester,
        budgets: FakeBudgetRepository([
          BudgetModel(month: DateTime(2026, 10), limit: 5000),
        ]),
      );
      expect(find.text('Monthly overview'), findsOneWidget);
      expect(inCard(find.text('October 2026')), findsOneWidget);
      expect(inCard(find.text('KSh 1,290.00')), findsOneWidget);
      expect(inCard(find.textContaining('left of')), findsOneWidget);
    });

    testWidgets('Day: today\'s figures, the date, and no going past today', (
      tester,
    ) async {
      await show(tester);
      await pick(tester, SpendPeriod.day);
      expect(find.text('Daily overview'), findsOneWidget);
      expect(rangeText(tester), 'Saturday, 31 October 2026');
      expect(find.byKey(const Key('overview-range-current')), findsOneWidget);
      expect(inCard(find.text('KSh 1,000.00')), findsOneWidget); // income
      expect(inCard(find.text('KSh 251.00')), findsOneWidget); // expenses
      // A day has no budget of its own.
      expect(inCard(find.textContaining('budget')), findsNothing);
      final next = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.chevron_right_rounded),
      );
      expect(next.onPressed, isNull);

      await tester.tap(find.byTooltip('Previous day'));
      await tester.pumpAndSettle();
      expect(rangeText(tester), 'Friday, 30 October 2026');
      expect(find.byKey(const Key('overview-range-current')), findsNothing);
      expect(
        find.text('No transactions on Friday, 30 October 2026'),
        findsOneWidget,
      );
    });

    testWidgets('Week: Monday to Sunday, clearly named', (tester) async {
      await show(tester);
      await pick(tester, SpendPeriod.week);
      expect(find.text('Weekly overview'), findsOneWidget);
      expect(rangeText(tester), 'Mon 26 Oct – Sun 1 Nov 2026');
      expect(find.text('This week'), findsOneWidget);
      expect(inCard(find.text('KSh 291.00')), findsOneWidget);

      await tester.tap(find.byTooltip('Previous week'));
      await tester.pumpAndSettle();
      expect(rangeText(tester), 'Mon 19 Oct – Sun 25 Oct 2026');
      expect(inCard(find.text('KSh 999.00')), findsWidgets);
    });

    testWidgets('Day and Week leave the shared month (Budgets, Trends) alone', (
      tester,
    ) async {
      final month = await show(tester);
      await pick(tester, SpendPeriod.week);
      for (var i = 0; i < 6; i++) {
        await tester.tap(find.byTooltip('Previous week'));
        await tester.pumpAndSettle();
      }
      expect(rangeText(tester), contains('Sep'));
      expect(month.value, DateTime(2026, 10));
      await pick(tester, SpendPeriod.month);
      expect(find.text('Monthly overview'), findsOneWidget);
      expect(inCard(find.text('October 2026')), findsOneWidget);
      expect(find.byKey(const Key('overview-range')), findsNothing);
    });

    testWidgets('loading, then an error with Retry', (tester) async {
      await show(tester, store: TransactionStore(_NeverLoads()), settle: false);
      await tester.tap(find.byKey(const Key('period-day')));
      await tester.pump();
      expect(inCard(find.byType(CircularProgressIndicator)), findsOneWidget);

      final failing = FakeTransactionRepository()
        ..loadError = const DataException('No connection.');
      await show(tester, store: TransactionStore(failing));
      await pick(tester, SpendPeriod.week);
      expect(find.textContaining('No connection.'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });
  });

  group('Home header', () {
    testWidgets('today\'s full date under a compact greeting', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      await pumpApp(
        tester,
        auth: FakeAuthService(signedInAs: FakeAuthService.googleUser),
      );
      final date = tester.widget<Text>(
        find.byKey(const Key('home-header-date')),
      );
      expect(date.data, Formatters.fullDate(DateTime.now()));
      final greeting = tester.widget<Text>(find.byKey(const Key('home-greeting')));
      expect(greeting.style!.fontSize, lessThanOrEqualTo(16));
      expect(greeting.data, endsWith(', Ann'));
    });
  });
}

/// Transactions that haven't arrived yet.
class _NeverLoads extends FakeTransactionRepository {
  @override
  Stream<List<TransactionModel>> watchAll() =>
      StreamController<List<TransactionModel>>().stream;
}
