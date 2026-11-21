import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/accounts/money_account.dart';
import 'package:pennywise/models/transaction_model.dart';
import 'package:pennywise/reports/spending_report.dart';
import 'package:pennywise/reports/spending_report_csv.dart';
import 'package:pennywise/reports/spending_report_pdf.dart';

final nov = DateTime(2026, 11, 10, 12);
final start = DateTime(2026, 11);
final end = DateTime(2026, 12);
final accounts = MoneyAccount.starterSet();

TransactionModel tx(
  TransactionType type,
  double amount, {
  String category = 'food',
  String description = 'x',
  String? accountId = 'mpesa-sim1',
  String? toAccountId,
  double? fee,
  double? interest,
  DateTime? date,
}) => TransactionModel(
  description: description,
  amount: amount,
  type: type,
  categoryId: category,
  date: date ?? nov,
  account: Account.mpesa,
  accountId: accountId,
  toAccountId: toAccountId,
  fee: fee,
  interest: interest,
);

SpendingReport report(
  List<TransactionModel> list, {
  String? accountId,
  bool hideSavings = false,
}) => SpendingReport.build(
  transactions: list,
  start: start,
  end: end,
  accountId: accountId,
  accounts: accounts,
  hideSavings: hideSavings,
);

void main() {
  test('money moves are listed but are not spending', () {
    final r = report([
      tx(TransactionType.expense, 500, description: 'Naivas'),
      // Fuliza repayment: 1,000 back, 30 of it interest.
      tx(
        TransactionType.debtRepayment,
        1000,
        category: 'fuliza',
        toAccountId: 'fuliza-sim1',
        interest: 30,
      ),
      // SIM 1 to SIM 2.
      tx(TransactionType.transfer, 2000, toAccountId: 'mpesa-sim2'),
      tx(
        TransactionType.savingsContribution,
        3000,
        category: 'savings',
        toAccountId: 'ziidi-sim1',
      ),
      tx(
        TransactionType.savingsWithdrawal,
        1000,
        category: 'savings',
        toAccountId: 'ziidi-sim1',
      ),
    ]);

    expect(r.spending, 530); // 500 + interest only
    expect(r.feesAndInterest, 30);
    expect(r.debtPrincipal, 970);
    expect(r.transfers, 2000);
    expect(r.netSaved, 2000);
    expect(r.transactions, hasLength(5));
    expect(
      r.transactions.map((t) => t.typeLabel),
      containsAll(['Expense', 'Repayment', 'Transfer', 'Savings']),
    );
    final transfer = r.transactions.firstWhere((t) => t.typeLabel == 'Transfer');
    expect(transfer.countsAsSpending, isFalse);
    expect(transfer.account, 'SIM 1 M-Pesa → SIM 2 M-Pesa');
  });

  test('fees count as spending under Fees', () {
    final r = report([
      tx(TransactionType.expense, 100, fee: 7),
      tx(TransactionType.transfer, 1000, toAccountId: 'mpesa-sim2', fee: 13),
    ]);
    expect(r.spending, 120);
    expect(r.feesAndInterest, 20);
    final fees = r.categories.firstWhere((c) => c.categoryId == 'fees');
    expect(fees.amount, 20);
    expect(fees.count, 2);
  });

  test('refunds reduce their category', () {
    final r = report([
      tx(TransactionType.expense, 1000, category: 'shopping'),
      tx(TransactionType.refund, 400, category: 'shopping'),
      tx(TransactionType.expense, 600, category: 'food'),
    ]);
    expect(r.spending, 1200);
    expect(r.refunds, 400);
    final shopping = r.categories.firstWhere((c) => c.categoryId == 'shopping');
    expect(shopping.amount, 600);
    expect(shopping.count, 2);
    expect(shopping.share, 0.5);
    final refund = r.transactions.firstWhere((t) => t.typeLabel == 'Refund');
    expect(refund.amount, 400); // money in
  });

  test('only the date range is included, end exclusive', () {
    final r = report([
      tx(TransactionType.expense, 1, date: DateTime(2026, 10, 31, 23, 59)),
      tx(TransactionType.expense, 2, date: DateTime(2026, 11, 1)),
      tx(TransactionType.expense, 4, date: DateTime(2026, 11, 30, 23, 59)),
      tx(TransactionType.expense, 8, date: DateTime(2026, 12, 1)),
    ]);
    expect(r.spending, 6);
    expect(r.transactions, hasLength(2));
    expect(r.lastDay, DateTime(2026, 11, 30));
  });

  test('account filter keeps one account, both sides of a move', () {
    final list = [
      tx(TransactionType.expense, 100),
      tx(TransactionType.expense, 200, accountId: 'mpesa-sim2'),
      tx(TransactionType.transfer, 500, toAccountId: 'mpesa-sim2'),
      tx(TransactionType.income, 50, accountId: null),
    ];
    final sim2 = report(list, accountId: 'mpesa-sim2');
    expect(sim2.accountName, 'SIM 2 M-Pesa');
    expect(sim2.spending, 200);
    expect(sim2.transactions, hasLength(2));
    // The transfer arrived on SIM 2.
    expect(
      sim2.transactions.firstWhere((t) => t.typeLabel == 'Transfer').amount,
      500,
    );
    final sim1 = report(list, accountId: 'mpesa-sim1');
    expect(sim1.spending, 100);
    expect(
      sim1.transactions.firstWhere((t) => t.typeLabel == 'Transfer').amount,
      -500,
    );
    expect(report(list).transactions, hasLength(4));
  });

  test('hide savings leaves savings amounts and rows out', () {
    final list = [
      tx(TransactionType.expense, 100),
      tx(
        TransactionType.savingsContribution,
        3000,
        category: 'savings',
        toAccountId: 'ziidi-sim1',
      ),
    ];
    final hidden = report(list, hideSavings: true);
    expect(hidden.netSaved, isNull);
    expect(hidden.transactions.map((t) => t.typeLabel), ['Expense']);
    expect(hidden.spending, 100);
    final csv = SpendingReportCsv.build(hidden);
    expect(csv, isNot(contains('3000')));
    expect(csv, isNot(contains('Net saved')));

    final shown = report(list);
    expect(shown.netSaved, 3000);
    expect(SpendingReportCsv.build(shown), contains('Net saved'));
  });

  group('CSV', () {
    test('quotes commas, quotes and line breaks', () {
      expect(SpendingReportCsv.field('plain'), 'plain');
      expect(SpendingReportCsv.field('Java, Westlands'), '"Java, Westlands"');
      expect(SpendingReportCsv.field('The "Hub"'), '"The ""Hub"""');
      expect(SpendingReportCsv.field('a\nb'), '"a\nb"');
      // Never a spreadsheet formula.
      expect(SpendingReportCsv.field('=SUM(A1)'), "'=SUM(A1)");
      expect(SpendingReportCsv.field('-12.50'), '-12.50');
    });

    test('amounts have 2 decimals and no separators', () {
      expect(SpendingReportCsv.amount(1234.5), '1234.50');
      expect(SpendingReportCsv.amount(-3), '-3.00');
      expect(SpendingReportCsv.amount(0.1 + 0.2), '0.30');
    });

    test('has summary, category and transaction sections', () {
      final r = report([
        tx(TransactionType.expense, 1500, description: 'Java, Westlands'),
      ]);
      final csv = SpendingReportCsv.build(r, generatedAt: DateTime(2026, 11, 19));
      final lines = csv.split('\r\n');
      expect(lines, contains('Period,2026-11-01 to 2026-11-30'));
      expect(lines, contains('Spending,1500.00'));
      expect(lines, contains('Food,1500.00,100.0,1'));
      expect(
        lines,
        contains('2026-11-10,"Java, Westlands",Expense,Food,'
            'SIM 1 M-Pesa,-1500.00,0.00'),
      );
      final noTx = SpendingReportCsv.build(r, includeTransactions: false);
      expect(noTx, isNot(contains('Westlands')));
    });
  });

  test('PDF builds over several pages, odd characters included', () async {
    final r = report([
      for (var i = 0; i < 150; i++)
        tx(TransactionType.expense, 10.0 + i, description: 'Shop $i 🛒 – “x”'),
    ]);
    final bytes = await SpendingReportPdf.build(r, userName: 'Test User');
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    expect(SpendingReportPdf.clean('A → B 🛒'), 'A -> B ?');
  });
}
