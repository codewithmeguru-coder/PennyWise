import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/accounts/money_account.dart';
import 'package:pennywise/data/data_exception.dart';
import 'package:pennywise/data/transaction_store.dart';
import 'package:pennywise/models/transaction_category.dart';
import 'package:pennywise/models/transaction_model.dart';
import 'package:pennywise/reports/fuliza_report.dart';
import 'package:pennywise/screens/fuliza_report_screen.dart';
import 'package:pennywise/widgets/charts/chart_style.dart';

import 'fake_transaction_repository.dart';

// Fuliza fee report: pure maths over saved transactions, and the screen.
// Records have the shape the Fuliza import saves; message wording is copied
// from real Fuliza messages, codes and amounts are made up.

final accounts = MoneyAccount.starterSet();

/// A loan as imported: Fuliza (SIM n) → M-Pesa (SIM n), with its fee.
TransactionModel loan(
  String code,
  DateTime date,
  double amount,
  double fee, {
  int? sim = 0,
  double? owed,
  bool ids = true,
  String? id,
}) {
  final n = (sim ?? 0) + 1;
  return TransactionModel(
    id: id ?? 'mpesa_${code}_FULIZA',
    description: 'Fuliza loan',
    amount: amount,
    type: TransactionType.transfer,
    categoryId: 'transfer',
    date: date,
    source: TransactionSource.mpesa,
    reference: code,
    smsText:
        '$code Confirmed. Fuliza M-PESA amount is Ksh $amount. Access '
        'Fee charged Ksh $fee.'
        '${owed == null ? '' : ' Total Fuliza M-PESA outstanding amount is '
                  'Ksh${owed.toStringAsFixed(2)} due on 21/11/26.'}',
    toAccount: Account.mpesa,
    fee: fee,
    accountId: ids ? 'fuliza-sim$n' : null,
    toAccountId: ids ? 'mpesa-sim$n' : null,
    simSlot: sim,
  );
}

/// A repayment as imported: M-Pesa (SIM n) → Fuliza (SIM n).
TransactionModel repay(
  String code,
  DateTime date,
  double amount, {
  int? sim = 0,
  bool fully = true,
  bool ids = true,
  double? interest,
}) {
  final n = (sim ?? 0) + 1;
  return TransactionModel(
    id: 'mpesa_$code',
    description: 'Fuliza repayment',
    amount: amount,
    type: TransactionType.debtRepayment,
    categoryId: 'debt_repayment',
    date: date,
    source: TransactionSource.mpesa,
    reference: code,
    smsText:
        '$code Confirmed. Ksh $amount from your M-PESA has been used to '
        '${fully ? 'fully' : 'partially'} pay your outstanding Fuliza M-PESA.',
    account: Account.mpesa,
    interest: interest,
    accountId: ids ? 'mpesa-sim$n' : null,
    toAccountId: ids ? 'fuliza-sim$n' : null,
    simSlot: sim,
  );
}

/// The payment a loan completed: same code, its own M-Pesa charge.
TransactionModel payment(
  String code,
  DateTime date,
  double amount, {
  double? fee,
}) => TransactionModel(
  id: 'mpesa_$code',
  description: 'Mama Pima',
  amount: amount,
  type: TransactionType.expense,
  categoryId: 'food',
  date: date,
  source: TransactionSource.mpesa,
  reference: code,
  fee: fee,
  accountId: 'mpesa-sim1',
  simSlot: 0,
);

DateTime d(int month, int day, [int hour = 9, int minute = 0, int s = 0]) =>
    DateTime(2026, month, day, hour, minute, s);

FulizaReport build(
  List<TransactionModel> ts, [
  FulizaFilter filter = const FulizaFilter(),
]) => FulizaReport.build(ts, accounts: accounts, filter: filter);

void main() {
  group('totals', () {
    test('fees are the loans\' access fees; borrowed and repaid are kept '
        'apart', () {
      final r = build([
        loan('UA1', d(10, 1), 100, 1.00, owed: 101),
        loan('UA2', d(10, 2), 50, 0.50, owed: 151.50),
        repay('UA3', d(10, 3), 151.50),
      ]);
      final t = r.totals;
      expect(t.loans, 2);
      expect(t.fees, closeTo(1.50, 1e-9));
      expect(t.borrowed, 150);
      expect(t.repaid, 151.50);
      expect(t.repayments, 1);
    });

    test('a repayment adds nothing to fees, even with interest on it', () {
      final r = build([
        loan('UB1', d(10, 1), 100, 1.00, owed: 101),
        repay('UB2', d(10, 2), 101, interest: 1.00),
      ]);
      expect(r.totals.fees, 1.00);
      expect(r.totals.repaid, 101);
    });

    test('the payment a loan completed shares its code but its own charge '
        'is not a Fuliza fee', () {
      final r = build([
        payment('UC1', d(10, 1), 300, fee: 7),
        loan('UC1', d(10, 1), 120, 1.20, owed: 121.20),
      ]);
      expect(r.entries, hasLength(1));
      expect(r.totals.fees, 1.20);
      expect(r.ledger.single.paidFor?.description, 'Mama Pima');
    });

    test('the same loan saved twice counts once', () {
      final r = build([
        loan('UD1', d(10, 1), 100, 1.00, owed: 101),
        loan('UD1', d(10, 1), 100, 1.00, owed: 101, id: 'manual-copy'),
        loan('UD1', d(10, 1), 100, 1.00, owed: 101), // same id again
      ]);
      expect(r.totals.loans, 1);
      expect(r.totals.fees, 1.00);
      expect(r.duplicatesIgnored, 2);
    });

    test('ordinary transfers and expenses are not Fuliza', () {
      final r = build([
        TransactionModel(
          id: 'w',
          description: 'Agent withdrawal',
          amount: 500,
          type: TransactionType.transfer,
          categoryId: 'transfer',
          date: d(10, 1),
          fee: 29,
          accountId: 'mpesa-sim1',
          toAccountId: 'cash',
        ),
        payment('UE1', d(10, 1), 80, fee: 0),
      ]);
      expect(r.isEmpty, isTrue);
      expect(r.totals.fees, 0);
    });
  });

  group('owed now', () {
    test('is the amount Safaricom last stated', () {
      final r = build([
        loan('UF1', d(10, 1), 100, 1.00, owed: 101),
        loan('UF2', d(10, 2), 50, 0.50, owed: 151.50),
      ]);
      final o = r.outstanding[0]!;
      expect(o.amount, 151.50);
      expect(o.confirmed, isTrue);
      expect(o.asOf, d(10, 2));
    });

    test('is zero after a full repayment', () {
      final r = build([
        loan('UG1', d(10, 1), 100, 1.00, owed: 101),
        repay('UG2', d(10, 2), 101),
      ]);
      expect(r.outstanding[0]!.amount, 0);
      expect(r.outstanding[0]!.confirmed, isTrue);
      expect(r.ledger.single.repaid, isTrue);
    });

    test('after a partial repayment it is estimated, not stated', () {
      final r = build([
        loan('UH1', d(10, 1), 100, 1.00, owed: 101),
        repay('UH2', d(10, 2), 40, fully: false),
      ]);
      expect(r.outstanding[0]!.amount, closeTo(61, 1e-9));
      expect(r.outstanding[0]!.confirmed, isFalse);
      expect(r.ledger.single.repaid, isFalse);
    });

    test('is unknown when no message states it', () {
      final r = build([loan('UI1', d(10, 1), 100, 1.00)]);
      expect(r.outstanding, isEmpty);
      expect(r.totalOutstanding, isNull);
    });
  });

  group('filters', () {
    final data = [
      loan('UJ1', d(9, 20), 100, 1.00, owed: 101),
      repay('UJ2', d(9, 30), 101),
      loan('UJ3', d(10, 5), 200, 2.00, owed: 202),
      loan('UJ4', d(10, 6), 30, 0.30, sim: 1, owed: 30.30),
    ];

    test('a month keeps only that month, and owed is as of its end', () {
      final sep = build(data, FulizaFilter.month(DateTime(2026, 9)));
      expect(sep.totals.fees, 1.00);
      expect(sep.totals.repaid, 101);
      expect(sep.outstanding[0]!.amount, 0); // as of 30 Sep
      expect(sep.outstanding.containsKey(1), isFalse); // nothing by then

      final oct = build(data, FulizaFilter.month(DateTime(2026, 10)));
      expect(oct.totals.fees, closeTo(2.30, 1e-9));
      expect(oct.totals.repaid, 0);
      expect(oct.outstanding[0]!.amount, 202);
    });

    test('a date range includes both end days', () {
      final r = build(
        data,
        FulizaFilter(from: DateTime(2026, 9, 30), to: DateTime(2026, 10, 5)),
      );
      expect(r.entries.map((e) => e.transaction.reference), ['UJ2', 'UJ3']);
    });

    test('a SIM filter applies to totals, owed, months and the ledger', () {
      final sim2 = build(data, const FulizaFilter(sim: FulizaSimFilter.sim2));
      expect(sim2.totals.fees, closeTo(0.30, 1e-9));
      expect(sim2.totals.borrowed, 30);
      expect(sim2.outstanding.keys, [1]);
      expect(sim2.monthlyFees.keys, [DateTime(2026, 10)]);
      expect(sim2.ledger.map((r) => r.entry.simSlot), [1]);

      final all = build(data);
      expect(all.bySim.keys, containsAll([0, 1]));
      expect(all.totalOutstanding, closeTo(232.30, 1e-9));
    });

    test('fees by month, per SIM', () {
      final m = build(data).monthlyFees;
      expect(m[DateTime(2026, 9)], {0: 1.00});
      expect(m[DateTime(2026, 10)]![0], 2.00);
      expect(m[DateTime(2026, 10)]![1], closeTo(0.30, 1e-9));
    });
  });

  group('missing SIM and older records', () {
    test('a record without a SIM counts under All SIMs only', () {
      final data = [
        loan('UK1', d(10, 1), 100, 1.00, sim: null, ids: false, owed: 101),
        loan('UK2', d(10, 2), 50, 0.50, owed: 50.50),
      ];
      final all = build(data);
      expect(all.totals.fees, 1.50);
      expect(all.unknownSim, 1);
      expect(all.bySim[null]!.fees, 1.00);
      // Nothing about an unknown SIM's debt is guessed.
      expect(all.outstanding.keys, [0]);

      final sim1 = build(data, const FulizaFilter(sim: FulizaSimFilter.sim1));
      expect(sim1.totals.fees, 0.50);
      expect(sim1.unknownSim, 0);
    });

    test('records without account ids are recognised by their wording, '
        'and the SIM comes from the account when the record has none', () {
      final r = build([
        loan(
          'UL1',
          d(10, 1),
          100,
          1.00,
          sim: null,
          owed: 101,
        ).withCategory('transfer'),
        repay('UL2', d(10, 2), 101, ids: false),
      ]);
      expect(r.entries, hasLength(2));
      // UL1 has no simSlot but its accounts are SIM 1's.
      expect(r.entries.first.simSlot, 0);
      expect(r.totals.repaid, 101);
    });

    test('no data at all', () {
      final r = build(const []);
      expect(r.isEmpty, isTrue);
      expect(r.totals.fees, 0);
      expect(r.ledger, isEmpty);
      expect(r.gaps, isEmpty);
      expect(r.totalOutstanding, isNull);
    });
  });

  group('unexplained owed amounts', () {
    // The real SIM 1 pattern: on 26 Sep the stated debt jumped by 101.00
    // more than one 40.00 loan explains (a 100.00 loan + 1.00 fee whose
    // message isn't on the phone), and on 16 Oct a full repayment was 3.00
    // more than the last stated debt (charges with no message).
    final sim1 = [
      loan('UM1', d(9, 26, 13, 56), 30, 0.30, owed: 124.89),
      loan('UM2', d(9, 26, 16, 29), 40, 0.40, owed: 266.29),
      repay('UM3', d(9, 27), 266.29),
      loan('UM4', d(10, 14), 252, 0.32, owed: 252.32),
      repay('UM5', d(10, 16), 255.32),
      loan('UM6', d(10, 19), 100, 1.00, owed: 101.00),
    ];

    test('the KSh 104 on SIM 1 is found, from the messages alone', () {
      final r = build(sim1);
      expect(r.gaps.map((g) => g.amount), [101.00, 3.00]);
      expect(r.totalGap, 104.00);
      expect(r.gaps.every((g) => g.simSlot == 0), isTrue);
      expect(r.gaps.first.after, d(9, 26, 13, 56));
      expect(r.gaps.first.at, d(9, 26, 16, 29));
    });

    test('it is reported, never added: totals stay what was saved, owed '
        'stays what Safaricom stated', () {
      final r = build(sim1);
      expect(r.totals.borrowed, 30 + 40 + 252 + 100);
      expect(r.totals.fees, closeTo(0.30 + 0.40 + 0.32 + 1.00, 1e-9));
      expect(r.outstanding[0]!.amount, 101.00);
    });

    test('it shows for SIM 1 and All, not for SIM 2', () {
      expect(
        build(sim1, const FulizaFilter(sim: FulizaSimFilter.sim2)).gaps,
        isEmpty,
      );
      expect(
        build(sim1, const FulizaFilter(sim: FulizaSimFilter.sim1)).totalGap,
        104.00,
      );
    });

    test('loans in the same minute arriving out of order are not a gap', () {
      final r = build([
        loan('UN1', d(10, 12, 14, 13), 1.82, 0.02, owed: 1.84),
        // Saved later in the minute but stated first by Safaricom.
        loan('UN2', d(10, 12, 14, 19, 10), 128, 1.28, owed: 171.52),
        loan('UN3', d(10, 12, 14, 19, 40), 40, 0.40, owed: 42.24),
        loan('UN4', d(10, 12, 14, 30), 20, 0.20, owed: 191.72),
      ]);
      expect(r.gaps, isEmpty);
      expect(r.outstanding[0]!.amount, 191.72);
    });

    test('a repayment then a loan in the same minute keep their order', () {
      final r = build([
        loan('UO1', d(10, 5, 15, 11), 200, 2.00, owed: 288.23),
        repay('UO2', d(10, 5, 15, 17, 5), 200, fully: false),
        loan('UO3', d(10, 5, 15, 17, 30), 20, 0.20, owed: 108.43),
      ]);
      expect(r.gaps, isEmpty);
    });
  });

  test('"Airtime & Data" is now "Airtime, Data & Minutes", same id', () {
    final c = DefaultCategories.byId('airtime_data');
    expect(c.name, 'Airtime, Data & Minutes');
    expect(c.type, TransactionType.expense);
    expect(
      DefaultCategories.all.where((c) => c.id == 'airtime_data'),
      hasLength(1),
    );
  });

  group('screen', () {
    // The report's own list (the summary grid scrolls inside it).
    final list = find.byType(Scrollable).first;

    Future<void> show(WidgetTester tester, TransactionStore store) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: FulizaReportScreen(store: store, accounts: accounts),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('summary, warning, charts and ledger', (tester) async {
      final repo = FakeTransactionRepository([
        loan('UP1', d(9, 26, 13, 56), 30, 0.30, owed: 124.89),
        loan('UP2', d(9, 26, 16, 29), 40, 0.40, owed: 266.29),
        repay('UP3', d(9, 27), 266.29),
        loan('UP4', d(10, 6), 30, 0.30, sim: 1, owed: 30.30),
      ]);
      await show(tester, TransactionStore(repo));

      expect(find.text('Fees paid'), findsOneWidget);
      expect(find.text('KSh 1.00'), findsOneWidget); // 0.30 + 0.40 + 0.30
      expect(find.text('KSh 30.30'), findsOneWidget); // owed: SIM 1 0 + SIM 2
      expect(find.textContaining('KSh 101.00 more owed'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Fees by month'),
        200,
        scrollable: list,
      );
      await tester.scrollUntilVisible(
        find.text('Fees by SIM'),
        200,
        scrollable: list,
      );
      expect(find.text('SIM 1'), findsWidgets); // chart legend
      await tester.scrollUntilVisible(
        find.text('All time'),
        -200,
        scrollable: list,
      );

      await tester.tap(find.text('SIM 2').first); // the SIM filter
      await tester.pumpAndSettle();
      expect(find.textContaining('more owed'), findsNothing);
      expect(find.text('Fees by SIM'), findsNothing);
      expect(find.text('KSh 0.30'), findsWidgets);

      await tester.scrollUntilVisible(
        find.text('Fee ledger'),
        200,
        scrollable: list,
      );
      expect(find.textContaining('Fee KSh 0.30 on KSh 30.00'), findsOneWidget);
    });

    testWidgets('empty', (tester) async {
      await show(tester, TransactionStore(FakeTransactionRepository()));
      expect(find.text('No Fuliza activity'), findsOneWidget);
    });

    testWidgets('error offers a retry', (tester) async {
      final repo = FakeTransactionRepository()
        ..loadError = const DataException('No connection');
      await show(tester, TransactionStore(repo));
      expect(find.text('Couldn\'t load transactions'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    group('clearing the date filter', () {
      // Dates relative to today, so "Month" (the current month) always
      // holds exactly one SIM 1 loan and one SIM 2 loan.
      final now = DateTime.now();
      final thisMonth = DateTime(now.year, now.month, 1, 9);
      final lastMonth = DateTime(now.year, now.month - 1, 2, 9);
      List<TransactionModel> data() => [
        loan('UQ1', lastMonth, 100, 1.00, owed: 101),
        loan('UQ2', thisMonth, 50, 0.50, owed: 151.50),
        loan('UQ3', thisMonth, 30, 0.30, sim: 1, owed: 30.30),
      ];

      final clear = find.byTooltip('Clear date filter');

      Future<void> showTall(WidgetTester tester) async {
        // Tall enough that every section, ledger included, is built.
        tester.view.physicalSize = const Size(1080, 7000);
        tester.view.devicePixelRatio = 2.75;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            home: FulizaReportScreen(
              store: TransactionStore(FakeTransactionRepository(data())),
              accounts: accounts,
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      List<String> monthLabels(WidgetTester tester) => tester
          .widget<GroupedBarChart>(find.byType(GroupedBarChart).first)
          .labels;
      int ledgerRows() => find.byType(ListTile).evaluate().length;

      testWidgets('no ✕ while showing all time', (tester) async {
        await showTall(tester);
        expect(clear, findsNothing);
      });

      testWidgets('✕ on a month goes back to all time and every section '
          'refreshes; the SIM choice stays', (tester) async {
        await showTall(tester);
        await tester.tap(find.text('SIM 1').first);
        await tester.pumpAndSettle();
        expect(find.text('KSh 1.50'), findsOneWidget); // all-time SIM 1 fees
        expect(monthLabels(tester), hasLength(2));
        expect(ledgerRows(), 2);

        await tester.tap(find.text('Month'));
        await tester.pumpAndSettle();
        expect(clear, findsOneWidget);
        expect(find.text('KSh 0.50'), findsWidgets); // this month only
        expect(find.text('KSh 1.50'), findsNothing);
        expect(monthLabels(tester), hasLength(1));
        expect(ledgerRows(), 1);
        expect(find.text('Fee KSh 1.00 on KSh 100.00'), findsNothing);

        await tester.tap(clear);
        await tester.pumpAndSettle();
        expect(clear, findsNothing);
        expect(find.text('KSh 1.50'), findsOneWidget);
        expect(monthLabels(tester), hasLength(2));
        expect(ledgerRows(), 2);
        expect(find.text('Fee KSh 1.00 on KSh 100.00'), findsOneWidget);
        // Still SIM 1: SIM 2's loan isn't back.
        expect(find.text('Fee KSh 0.30 on KSh 30.00'), findsNothing);
        expect(find.text('Fees by SIM'), findsNothing);
      });

      testWidgets('✕ on a date range clears it too', (tester) async {
        await showTall(tester);
        await tester.tap(find.text('Dates…'));
        await tester.pumpAndSettle();
        // Flutter's own range picker header overflows under the test font
        // (every glyph a full square); nothing of PennyWise's. Only that
        // one known overflow is let through.
        final picker = tester.takeException();
        expect(
          picker == null || '$picker'.contains('RenderFlex overflowed'),
          isTrue,
          reason: '$picker',
        );
        // Type the range: just this month's first day.
        await tester.tap(find.byIcon(Icons.edit_outlined));
        await tester.pumpAndSettle();
        String typed(DateTime d) =>
            '${d.month.toString().padLeft(2, '0')}/'
            '${d.day.toString().padLeft(2, '0')}/${d.year}';
        final fields = find.byType(TextField);
        await tester.enterText(fields.at(0), typed(thisMonth));
        await tester.enterText(fields.at(1), typed(thisMonth));
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();

        expect(clear, findsOneWidget);
        expect(find.text('KSh 0.80'), findsOneWidget); // both SIMs, one day
        expect(ledgerRows(), 2);

        await tester.tap(clear);
        await tester.pumpAndSettle();
        expect(clear, findsNothing);
        expect(find.text('Dates…'), findsOneWidget);
        expect(find.text('KSh 1.80'), findsOneWidget); // all time, all SIMs
        expect(ledgerRows(), 3);
        expect(monthLabels(tester), hasLength(2));
      });
    });
  });
}
