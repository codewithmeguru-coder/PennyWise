import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/models/duplicate_finder.dart';
import 'package:pennywise/models/transaction_model.dart';
import 'package:pennywise/sms/sms_gateway.dart';

import 'fake_sms.dart';
import 'fake_transaction_repository.dart';
import 'test_app.dart';

// In memory only: no Firestore record is read or changed, and nothing is
// ever merged or deleted by the matcher.

final day = DateTime(2026, 10, 23, 12);

TransactionModel sms(
  String id,
  double amount, {
  TransactionType type = TransactionType.expense,
  DateTime? date,
  double? fee,
  String description = 'Naivas',
  String? accountId,
  Account? account = Account.mpesa,
  Account? toAccount,
  String? toAccountId,
}) =>
    TransactionModel(
      id: id,
      description: description,
      amount: amount,
      type: type,
      categoryId: 'food',
      date: date ?? day,
      source: TransactionSource.mpesa,
      reference: id,
      account: account,
      toAccount: toAccount,
      fee: fee,
      accountId: accountId,
      toAccountId: toAccountId,
    );

TransactionModel manual(
  double amount, {
  String id = '',
  TransactionType type = TransactionType.expense,
  DateTime? date,
  String description = 'Groceries',
  String? accountId,
  Account? account = Account.mpesa,
  Account? toAccount,
  String? toAccountId,
}) =>
    TransactionModel(
      id: id,
      description: description,
      amount: amount,
      type: type,
      categoryId: 'food',
      date: date ?? day.add(const Duration(hours: 1)),
      account: account,
      toAccount: toAccount,
      accountId: accountId,
      toAccountId: toAccountId,
    );

List<String> ids(List<TransactionModel> list) => [for (final t in list) t.id];

void main() {
  group('matcher', () {
    List<String> matches(TransactionModel draft, List<TransactionModel> all) =>
        ids(DuplicateFinder.smsMatchesFor(draft, all));

    test('exact amount, and amount plus the SMS fee', () {
      expect(matches(manual(250), [sms('a', 250)]), ['a']);
      expect(matches(manual(257), [sms('a', 250, fee: 7)]), ['a']);
      expect(matches(manual(257), [sms('a', 250)]), isEmpty);
      expect(matches(manual(250.01), [sms('a', 250)]), isEmpty);
    });

    test('same day or the day next to it; not further apart', () {
      expect(matches(manual(250, date: day.add(const Duration(days: 1))),
          [sms('a', 250)]), ['a']);
      expect(matches(manual(250, date: day.subtract(const Duration(days: 1))),
          [sms('a', 250)]), ['a']);
      expect(matches(manual(250, date: day.add(const Duration(days: 3))),
          [sms('a', 250)]), isEmpty);
    });

    test('SIM 1 never matches SIM 2; Cash never matches M-Pesa', () {
      expect(
          matches(manual(250, accountId: 'mpesa-sim2'),
              [sms('a', 250, accountId: 'mpesa-sim1')]),
          isEmpty);
      expect(
          matches(manual(250, accountId: 'mpesa-sim1'),
              [sms('a', 250, accountId: 'mpesa-sim1')]),
          ['a']);
      // Unknown on one side doesn't rule it out.
      expect(matches(manual(250), [sms('a', 250, accountId: 'mpesa-sim1')]),
          ['a']);
      expect(matches(manual(250, account: Account.cash), [sms('a', 250)]),
          isEmpty);
    });

    test('a cash withdrawal matches only the same withdrawal', () {
      final smsWithdrawal = sms('w', 1000,
          type: TransactionType.transfer,
          toAccount: Account.cash,
          fee: 29);
      expect(
          matches(
              manual(1000,
                  type: TransactionType.transfer, toAccount: Account.cash),
              [smsWithdrawal]),
          ['w']);
      expect(
          matches(manual(1029,
              type: TransactionType.transfer, toAccount: Account.cash),
              [smsWithdrawal]),
          ['w']);
      expect(
          matches(
              manual(1000,
                  type: TransactionType.transfer, toAccount: Account.bank),
              [smsWithdrawal]),
          isEmpty);
    });

    test('different types never match; a refund never matches an expense', () {
      expect(matches(manual(250, type: TransactionType.income), [sms('a', 250)]),
          isEmpty);
      expect(matches(manual(250, type: TransactionType.refund), [sms('a', 250)]),
          isEmpty);
    });

    test('SMS against SMS is never compared (codes handle that)', () {
      expect(matches(sms('new', 250), [sms('a', 250)]), isEmpty);
      expect(
          ids(DuplicateFinder.manualMatchesFor(
              sms('new', 250), [sms('a', 250)])),
          isEmpty);
    });

    test('Ziidi autosaves, Fuliza loans and moves between own lines are '
        'left out', () {
      expect(
          matches(manual(1, type: TransactionType.savingsContribution),
              [sms('z', 1, type: TransactionType.savingsContribution)]),
          isEmpty);
      expect(
          matches(manual(500, type: TransactionType.savingsContribution),
              [sms('z', 500, type: TransactionType.savingsContribution)]),
          ['z']);
      expect(
          matches(manual(300, type: TransactionType.transfer,
                  toAccount: Account.mpesa, account: Account.mpesa),
              [sms('mpesa_X_FULIZA', 300, type: TransactionType.transfer)]),
          isEmpty);
      // SIM 1 -> SIM 2 by hand: both sides are M-Pesa.
      expect(
          matches(
              manual(500,
                  type: TransactionType.transfer,
                  accountId: 'mpesa-sim1',
                  toAccountId: 'mpesa-sim2'),
              [
                sms('t', 500,
                    type: TransactionType.transfer,
                    accountId: 'mpesa-sim1',
                    toAccountId: 'mpesa-sim2'),
              ]),
          isEmpty);
    });

    test('an SMS already matched by another manual entry isn\'t offered '
        'again', () {
      final earlier = manual(250, id: 'm1', description: 'Lunch');
      expect(matches(manual(250), [sms('a', 250), earlier]), isEmpty);
      // ...but a second SMS for the same amount still is.
      expect(matches(manual(250), [sms('a', 250), sms('b', 250), earlier]),
          ['b']);
    });

    test('best match first: exact amount, shared word, then closest time',
        () {
      final all = [
        sms('fee', 243, fee: 7, description: 'Groceries shop'),
        sms('far', 250, date: day.subtract(const Duration(hours: 20))),
        sms('near', 250, date: day.add(const Duration(minutes: 30))),
        sms('word', 250,
            date: day.subtract(const Duration(hours: 10)),
            description: 'Groceries Naivas'),
      ];
      expect(matches(manual(250), all), ['word', 'near', 'far', 'fee']);
    });

    test('an SMS arriving after a manual entry finds it', () {
      final lunch = manual(250, id: 'm1', description: 'Lunch');
      expect(ids(DuplicateFinder.manualMatchesFor(sms('a', 250), [lunch])),
          ['m1']);
      expect(ids(DuplicateFinder.manualMatchesFor(sms('a', 99), [lunch])),
          isEmpty);
    });
  });

  group('in the app', () {
    final now = DateTime.now();
    final smsNaivas = TransactionModel(
      id: 'mpesa_UJMAB1CD31',
      description: 'Naivas',
      amount: 250,
      type: TransactionType.expense,
      categoryId: 'food',
      date: now.subtract(const Duration(minutes: 20)),
      source: TransactionSource.mpesa,
      reference: 'UJMAB1CD31',
      account: Account.mpesa,
      simSlot: 0,
    );

    Future<FakeTransactionRepository> fillNewExpense(
        WidgetTester tester, String amount) async {
      final repo = await pumpApp(tester,
          repository: FakeTransactionRepository([smsNaivas]));
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Amount'), amount);
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Description'), 'Groceries');
      await scrollAndTap(tester, 'Food');
      await scrollAndTap(tester, 'Save transaction');
      return repo;
    }

    testWidgets('a matching new entry asks first; "Go back" keeps the form',
        (tester) async {
      final repo = await fillNewExpense(tester, '250');
      expect(find.text('Already recorded?'), findsOneWidget);
      expect(find.textContaining('Naivas · KSh 250.00'), findsOneWidget);
      expect(find.textContaining('SIM 1'), findsOneWidget);
      expect(repo.items, hasLength(1)); // nothing saved yet

      await tester.tap(find.text('Go back'));
      await tester.pumpAndSettle();
      expect(find.text('Add transaction'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '250'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Groceries'), findsOneWidget);
      expect(repo.items, hasLength(1));
    });

    testWidgets('"Save anyway" saves exactly one new transaction',
        (tester) async {
      final repo = await fillNewExpense(tester, '250');
      await tester.tap(find.text('Save anyway'));
      await tester.pumpAndSettle();
      expect(repo.items, hasLength(2));
      expect(repo.items.where((t) => t.description == 'Groceries'),
          hasLength(1));
      expect(find.text('Already recorded?'), findsNothing);
    });

    testWidgets('"Open existing" saves nothing and opens the SMS one',
        (tester) async {
      final repo = await fillNewExpense(tester, '250');
      await tester.tap(find.text('Open existing'));
      await tester.pumpAndSettle();
      expect(repo.items, hasLength(1));
      expect(find.text('Edit transaction'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Naivas'), findsOneWidget);
    });

    testWidgets('no question for a different amount', (tester) async {
      final repo = await fillNewExpense(tester, '260');
      expect(find.text('Already recorded?'), findsNothing);
      expect(repo.items, hasLength(2));
    });

    testWidgets('editing an existing entry is never checked', (tester) async {
      final lunch = TransactionModel(
        id: 'm1',
        description: 'Lunch',
        amount: 250,
        type: TransactionType.expense,
        categoryId: 'food',
        date: now,
        account: Account.mpesa,
      );
      // The SMS is "taken" by Lunch, and Lunch itself is being edited.
      final repo = await pumpApp(tester,
          repository: FakeTransactionRepository([smsNaivas, lunch]));
      await scrollAndTap(tester, 'Lunch');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Description'), 'Team lunch');
      await scrollAndTap(tester, 'Save changes');
      expect(find.text('Already recorded?'), findsNothing);
      expect(repo.items.firstWhere((t) => t.id == 'm1').description,
          'Team lunch');
      expect(repo.items, hasLength(2));
    });

    testWidgets('an SMS that repeats a manual entry is saved, with a Review '
        'notice', (tester) async {
      final lunch = TransactionModel(
        id: 'm1',
        description: 'Lunch',
        amount: 500,
        type: TransactionType.expense,
        categoryId: 'food',
        date: now.subtract(const Duration(minutes: 5)),
        account: Account.mpesa,
      );
      final gateway = FakeSmsGateway(permissionGranted: true);
      final repo = await pumpApp(tester,
          repository: FakeTransactionRepository([lunch]),
          sms: gateway,
          smsSettings: FakeSmsSettings(enabled: true, last: now));

      gateway.receive(RawSms(
        sender: 'MPESA',
        body: 'TJ6AB1CD2E Confirmed. Ksh500.00 paid to NAIVAS. on 6/10/26 at '
            '1:20 PM.New M-PESA balance is Ksh2,700.00.',
        date: now,
      ));
      await tester.pumpAndSettle();

      expect(repo.items, hasLength(2)); // imported as usual
      expect(find.textContaining('Possible duplicate of "Lunch"'),
          findsOneWidget);
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      expect(find.text('Edit transaction'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Lunch'), findsOneWidget);
      expect(repo.items, hasLength(2)); // nothing removed
    });
  });
}
