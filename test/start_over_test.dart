import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/accounts/account_balances.dart';
import 'package:pennywise/accounts/account_repository.dart';
import 'package:pennywise/accounts/money_account.dart';
import 'package:pennywise/models/ledger.dart';
import 'package:pennywise/models/transaction_model.dart';
import 'package:pennywise/sms/sms_gateway.dart';
import 'package:pennywise/sms/sms_import_service.dart';
import 'package:pennywise/sms/sms_parser.dart';
import 'package:pennywise/sms/sms_transaction.dart';

import 'fake_accounts.dart';
import 'fake_sms.dart';
import 'fake_transaction_repository.dart';
import 'test_app.dart';

// "Start over": every account gets a starting balance and the moment it was
// set (openingDate). Balances are then that starting balance plus the
// account's transactions dated from that moment on, using the same
// AccountBalance / Ledger calculation as before. In memory only: no
// Firestore, no phone, no real SMS.

/// The moment of the fresh start in the unit tests.
final start = DateTime(2026, 10, 23, 12);
DateTime after(int minutes) => start.add(Duration(minutes: minutes));

/// The starter accounts after "Start over" with these balances (Fuliza as a
/// negative balance: the amount owed), every other account at 0.
List<MoneyAccount> startedOver([
  Map<String, double> balances = const {
    'mpesa-sim1': 1500,
    'mpesa-sim2': 200,
    'ziidi-sim1': 50,
    'fuliza-sim1': -100,
    'cash': 300,
  },
]) =>
    [
      for (final a in MoneyAccount.starterSet())
        a.copyWith(openingBalance: balances[a.id] ?? 0, openingDate: start),
    ];

TransactionModel tx(
  TransactionType type,
  double amount, {
  String? from,
  String? to,
  double? fee,
  DateTime? date,
  String id = '',
}) =>
    TransactionModel(
      id: id,
      description: 'x',
      amount: amount,
      type: type,
      categoryId: switch (type) {
        TransactionType.income => 'salary',
        TransactionType.transfer => 'transfer',
        TransactionType.savingsContribution => 'savings',
        TransactionType.savingsWithdrawal => 'savings_withdrawal',
        TransactionType.debtRepayment => 'debt_repayment',
        _ => 'food',
      },
      date: date ?? after(5),
      accountId: from,
      toAccountId: to,
      fee: fee,
    );

/// The card balance of account [id].
double balance(String id, List<TransactionModel> txs,
        [List<MoneyAccount>? accounts]) =>
    AccountBalance.of(
            (accounts ?? startedOver()).firstWhere((a) => a.id == id), txs)
        .shown;

void main() {
  test('1. Start over sets the opening balances', () {
    for (final (id, expected) in [
      ('mpesa-sim1', 1500.0),
      ('mpesa-sim2', 200.0),
      ('ziidi-sim1', 50.0),
      ('ziidi-sim2', 0.0),
      ('fuliza-sim1', -100.0), // KSh 100 owed
      ('cash', 300.0),
    ]) {
      expect(balance(id, const []), expected, reason: id);
    }
    final b = AccountBalance.of(startedOver().first, const []);
    expect(b.isEstimate, isFalse);
  });

  test('2. a new expense lowers only the chosen account', () {
    final txs = [tx(TransactionType.expense, 300, from: 'mpesa-sim2')];
    expect(balance('mpesa-sim2', txs), -100);
    expect(balance('mpesa-sim1', txs), 1500);
  });

  test('3. new income raises the chosen account', () {
    final txs = [tx(TransactionType.income, 2000, from: 'mpesa-sim1')];
    expect(balance('mpesa-sim1', txs), 3500);
  });

  test('4. a transfer moves money between the two accounts only', () {
    final txs = [
      tx(TransactionType.transfer, 500, from: 'mpesa-sim1', to: 'mpesa-sim2'),
    ];
    expect(balance('mpesa-sim1', txs), 1000);
    expect(balance('mpesa-sim2', txs), 700);
    final ledger = Ledger.of(txs);
    expect(ledger.spending, 0);
    expect(ledger.income, 0);
  });

  test('5. withdrawal of 1,000 with a 29 fee: source -1,029, Cash +1,000, '
      'only 29 is spending', () {
    final txs = [
      tx(TransactionType.transfer, 1000,
          from: 'mpesa-sim1', to: 'cash', fee: 29),
    ];
    expect(balance('mpesa-sim1', txs), 1500 - 1029);
    expect(balance('cash', txs), 1300);
    expect(Ledger.of(txs).spending, 29);
    expect(Ledger.of(txs).income, 0);
  });

  test('6. Ziidi: contributions and withdrawals move both balances', () {
    final txs = [
      tx(TransactionType.savingsContribution, 50,
          from: 'mpesa-sim2', to: 'ziidi-sim2'),
      tx(TransactionType.savingsWithdrawal, 20,
          from: 'mpesa-sim2', to: 'ziidi-sim2', date: after(10)),
    ];
    expect(balance('mpesa-sim2', txs), 200 - 50 + 20);
    expect(balance('ziidi-sim2', txs), 30);
    expect(balance('ziidi-sim1', txs), 50); // the other SIM's Ziidi
    expect(Ledger.of(txs).spending, 0);
    expect(Ledger.of(txs).income, 0);
  });

  test('7. Fuliza: borrowing adds to the debt (with its fee), repaying '
      'reduces it; the fee is spending once', () {
    final borrowed = [
      // Fuliza covers 300 of a payment, with a 3 access fee on the loan.
      tx(TransactionType.transfer, 300,
          from: 'fuliza-sim1', to: 'mpesa-sim1', fee: 3),
    ];
    expect(balance('fuliza-sim1', borrowed), -403); // 100 + 300 + 3 owed
    expect(balance('mpesa-sim1', borrowed), 1800);
    expect(Ledger.of(borrowed).spending, 3);

    final repaid = [
      ...borrowed,
      tx(TransactionType.debtRepayment, 403,
          from: 'mpesa-sim1', to: 'fuliza-sim1', date: after(30)),
    ];
    expect(balance('fuliza-sim1', repaid), 0); // nothing owed
    expect(balance('mpesa-sim1', repaid), 1800 - 403);
    expect(Ledger.of(repaid).spending, 3); // the fee, still only once
    // SIM 2's Fuliza is untouched.
    expect(balance('fuliza-sim2', repaid), 0);
  });

  test('8 and 9. editing or deleting a transaction recalculates', () {
    final original = tx(TransactionType.expense, 300, from: 'mpesa-sim1');
    expect(balance('mpesa-sim1', [original]), 1200);
    // The calculation always starts from the stored list, so an edit or a
    // delete is simply a different list (see also the widget test below).
    final edited = TransactionModel(
      description: original.description,
      amount: 500,
      type: original.type,
      categoryId: original.categoryId,
      date: original.date,
      accountId: 'mpesa-sim2', // moved to the other SIM
    );
    expect(balance('mpesa-sim1', [edited]), 1500);
    expect(balance('mpesa-sim2', [edited]), -300);
    expect(balance('mpesa-sim1', const []), 1500); // deleted
  });

  test('10. history before Start over is kept but not counted again', () {
    final old = tx(TransactionType.expense, 9000,
        from: 'mpesa-sim1', date: start.subtract(const Duration(days: 3)));
    final txs = [tx(TransactionType.expense, 100, from: 'mpesa-sim1'), old];
    expect(balance('mpesa-sim1', txs), 1400); // only the new 100
    // Still part of the history and of that month's report.
    expect(Ledger.of(txs).spending, 9100);
    // An SMS balance stated before Start over doesn't override it either.
    final oldSms = TransactionModel(
      description: 'Old SMS',
      amount: 10,
      type: TransactionType.expense,
      categoryId: 'food',
      date: start.subtract(const Duration(hours: 1)),
      accountId: 'mpesa-sim1',
      smsText: 'X Confirmed. Ksh10.00 paid to Y. New M-PESA balance is '
          'Ksh5.00.',
    );
    expect(balance('mpesa-sim1', [oldSms]), 1500);
  });

  test('11. rule for backdating: only transactions dated at or after the '
      'Start over moment count', () {
    // Added after Start over but dated before it: history only, because the
    // balance typed in already included it.
    final backdated = tx(TransactionType.expense, 250,
        from: 'mpesa-sim1', date: start.subtract(const Duration(minutes: 1)));
    expect(balance('mpesa-sim1', [backdated]), 1500);
    // Exactly at the moment, or later: counts.
    expect(balance('mpesa-sim1', [tx(TransactionType.expense, 250,
        from: 'mpesa-sim1', date: start)]), 1250);
  });

  test('12. hidden accounts: not in Home totals, and showing one again '
      'never brings back the whole history', () {
    final accounts = [
      for (final a in startedOver())
        a.id == 'cash' ? a.copyWith(active: false) : a,
    ];
    final active = accounts.where((a) => a.active).toList();
    final txs = [
      tx(TransactionType.transfer, 1000,
          from: 'mpesa-sim1', to: 'cash', fee: 29),
    ];
    // Hidden Cash still keeps its own balance...
    expect(balance('cash', txs, accounts), 1300);
    // ...but Home adds up only what is shown.
    final totals = AccountBalance.totals(active, txs)!;
    expect(totals.available, (1500 - 1029) + 200);
    expect(totals.savings, 50);

    // An account shown again (or added) without a starting balance: Home
    // keeps using the cards, with that card's estimate, instead of
    // switching back to adding up all history.
    final shownAgain = [
      ...active,
      MoneyAccount.starterSet().firstWhere((a) => a.id == 'cash'),
    ];
    final withCash = AccountBalance.totals(shownAgain, txs)!;
    expect(withCash.available, (1500 - 1029) + 200 + 1000);
  });

  test('12b. an SMS cash withdrawal still records both sides when Cash is '
      'hidden', () async {
    final store = AccountStore(FakeAccountRepository([
      for (final a in startedOver())
        a.id == 'cash' ? a.copyWith(active: false) : a,
    ]));
    await Future<void>.delayed(Duration.zero);
    final t = SmsImportService.toTransaction(
      _parse(_withdrawal)!,
      simSlot: 1,
      accounts: store,
    );
    expect(t.type, TransactionType.transfer);
    expect(t.accountId, 'mpesa-sim2');
    expect(t.toAccountId, 'cash');
  });

  test('SMS imports use the same calculation and are counted once', () async {
    final accounts = startedOver();
    final store = AccountStore(FakeAccountRepository(accounts));
    await Future<void>.delayed(Duration.zero);
    final repo = FakeTransactionRepository();
    final service = SmsImportService(
      gateway: FakeSmsGateway(permissionGranted: true),
      settings: FakeSmsSettings(enabled: true),
      save: (t, key) => repo.addDetected(t, dedupeKey: key),
      accounts: () => store,
    );
    await service.start();
    final sms = RawSms(
        sender: 'MPESA', body: _tillPayment, date: after(5), simSlot: 0);
    await service.handle(sms);
    await service.handle(sms); // the same message again
    expect(repo.items, hasLength(1));
    // The SMS states the new balance, which the M-Pesa card shows.
    expect(balance('mpesa-sim1', repo.items, accounts), 1750);
    final computed = AccountBalance.of(accounts.first, repo.items).computed;
    expect(computed, 1500 - 250); // the payment counted once
  });

  group('on the Home screen', () {
    void phone(WidgetTester tester) {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.8125;
      addTearDown(tester.view.reset);
    }

    final now = DateTime.now();
    final reset = now.subtract(const Duration(hours: 1));
    List<MoneyAccount> accountsNow() => [
          for (final a in MoneyAccount.starterSet())
            a.copyWith(
              openingBalance: switch (a.id) {
                'mpesa-sim1' => 1500,
                'mpesa-sim2' => 200,
                'cash' => 300,
                _ => 0,
              },
              openingDate: reset,
            ),
        ];

    testWidgets('8, 9 and 13. edit and delete update the balance, which '
        'survives reopening the app', (tester) async {
      phone(tester);
      final accounts = FakeAccountRepository(accountsNow());
      final txs = FakeTransactionRepository([
        TransactionModel(
          id: 'old',
          description: 'Last month salary',
          amount: 5000,
          type: TransactionType.income,
          categoryId: 'salary',
          date: now.subtract(const Duration(days: 40)),
          accountId: 'mpesa-sim1',
        ),
        TransactionModel(
          id: 'g1',
          description: 'Groceries',
          amount: 300,
          type: TransactionType.expense,
          categoryId: 'food',
          date: now,
          accountId: 'mpesa-sim1',
        ),
      ]);
      await pumpApp(tester, repository: txs, accounts: accounts);
      // 1,500 - 300 + 200 + 300; last month's 5,000 doesn't count.
      expect(find.text('KSh 1,700.00'), findsOneWidget);

      await scrollAndTap(tester, 'Groceries');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Amount'), '500');
      await scrollAndTap(tester, 'Save changes');
      await scrollToTop(tester);
      expect(find.text('KSh 1,500.00'), findsOneWidget);

      await scrollAndTap(tester, 'Groceries');
      await tester.tap(find.byTooltip('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
      await scrollToTop(tester);
      expect(find.text('KSh 2,000.00'), findsOneWidget);
      expect(txs.items.map((t) => t.id), ['old']); // history kept

      // Reopen: a fresh app over the same stored data.
      await tester.pumpWidget(const SizedBox());
      await pumpApp(tester, repository: txs, accounts: accounts);
      expect(find.text('KSh 2,000.00'), findsOneWidget);
    });
  });
}

const _tillPayment = 'UJMAB1CD31 Confirmed. Ksh250.00 paid to NAIVAS. on '
    '23/10/26 at 1:30 PM.New M-PESA balance is Ksh1,750.00. Transaction '
    'cost, Ksh0.00.';
const _withdrawal = 'UJMAB1CD33 Confirmed.on 23/10/26 at 1:40 PMWithdraw '
    'Ksh1,000.00 from 123456 - MAMA AGENCIES New M-PESA balance is '
    'Ksh720.00. Transaction cost, Ksh29.00.';

SmsTransaction? _parse(String body) =>
    SmsParser.parse(sender: 'MPESA', body: body, date: after(5));
