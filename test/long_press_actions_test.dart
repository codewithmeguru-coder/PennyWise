import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/accounts/money_account.dart';
import 'package:pennywise/data/data_exception.dart';
import 'package:pennywise/models/transaction_model.dart';
import 'package:pennywise/sms/sms_gateway.dart';
import 'package:pennywise/widgets/account_cards.dart';

import 'fake_accounts.dart';
import 'fake_sms.dart';
import 'fake_transaction_repository.dart';
import 'test_app.dart';

// In memory only: no Firestore record is read or changed.

final now = DateTime.now();

TransactionModel expense(String id, String description, double amount,
        {int minutesAgo = 0}) =>
    TransactionModel(
      id: id,
      description: description,
      amount: amount,
      type: TransactionType.expense,
      categoryId: 'food',
      date: now.subtract(Duration(minutes: minutesAgo)),
      account: Account.mpesa,
    );

final lunch = expense('l', 'Lunch', 300, minutesAgo: 5);
final books = expense('b', 'Books', 1200, minutesAgo: 10);
final salary = TransactionModel(
  id: 's',
  description: 'Salary',
  amount: 5000,
  type: TransactionType.income,
  categoryId: 'salary',
  date: now.subtract(const Duration(minutes: 30)),
  account: Account.mpesa,
);

/// Every delete is rejected, as Firestore would when offline rules fail.
class _RejectsDeletes extends FakeTransactionRepository {
  _RejectsDeletes(super.initial);

  @override
  Future<void> delete(String id) async =>
      throw const DataException('Couldn\'t delete. Check your connection.');
}

Future<void> longPress(WidgetTester tester, String text) async {
  // Home's recent list sits below the monthly overview: scroll until the
  // row is built and can be pressed.
  for (var i = 0;
      i < 20 && find.text(text).hitTestable().evaluate().isEmpty;
      i++) {
    await tester.drag(
        find.byType(Scrollable).hitTestable().first, const Offset(0, -300));
    await tester.pumpAndSettle();
  }
  await tester.ensureVisible(find.text(text).first);
  await tester.pumpAndSettle();
  await tester.longPress(find.text(text).first);
  await tester.pumpAndSettle();
}

void phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.8125;
  addTearDown(tester.view.reset);
}

Future<void> chooseDelete(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(ListTile, 'Delete'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('long press opens Edit / Delete and changes nothing',
      (tester) async {
    phone(tester);
    final repo = await pumpApp(tester,
        repository: FakeTransactionRepository([lunch, books, salary]));
    await longPress(tester, 'Lunch');
    expect(find.widgetWithText(ListTile, 'Edit'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Delete'), findsOneWidget);
    expect(repo.items, hasLength(3));

    await tester.tap(find.widgetWithText(ListTile, 'Edit'));
    await tester.pumpAndSettle();
    expect(find.text('Edit transaction'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Lunch'), findsOneWidget);
  });

  testWidgets('closing the menu or cancelling keeps the transaction',
      (tester) async {
    phone(tester);
    final repo = await pumpApp(tester,
        repository: FakeTransactionRepository([lunch, books, salary]));
    await longPress(tester, 'Lunch');
    await tester.tapAt(const Offset(10, 10)); // outside the sheet
    await tester.pumpAndSettle();
    expect(repo.items, hasLength(3));

    await longPress(tester, 'Lunch');
    await chooseDelete(tester);
    expect(find.text('Delete transaction?'), findsOneWidget);
    expect(find.textContaining('Lunch · KSh 300.00'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(repo.items, hasLength(3));
    expect(find.text('Lunch'), findsOneWidget);
  });

  testWidgets('confirming deletes only that one; totals follow',
      (tester) async {
    phone(tester);
    final repo = await pumpApp(tester,
        repository: FakeTransactionRepository([lunch, books, salary]));
    // 5,000 - 300 - 1,200
    expect(find.text('KSh 3,500.00'), findsOneWidget);

    await longPress(tester, 'Lunch');
    await chooseDelete(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(repo.items.map((t) => t.id), unorderedEquals(['b', 's']));
    expect(find.text('Deleted "Lunch"'), findsOneWidget);
    await scrollToTop(tester);
    expect(find.text('KSh 3,800.00'), findsOneWidget);
    await showRecent(tester);
    expect(find.text('Lunch'), findsNothing);
  });

  testWidgets('a failed delete shows the error, not success', (tester) async {
    phone(tester);
    final repo = await pumpApp(tester,
        repository: _RejectsDeletes([lunch, books]));
    await longPress(tester, 'Lunch');
    await chooseDelete(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Couldn\'t delete. Check your connection.'),
        findsOneWidget);
    expect(find.text('Deleted "Lunch"'), findsNothing);
    expect(repo.items, hasLength(2));
  });

  testWidgets('a transfer is one record: deleting it restores both accounts',
      (tester) async {
    phone(tester);
    final start = now.subtract(const Duration(hours: 1));
    final accounts = FakeAccountRepository([
      for (final a in MoneyAccount.starterSet())
        a.copyWith(
          openingBalance: switch (a.id) {
            'mpesa-sim1' => 1500,
            'cash' => 300,
            _ => 0,
          },
          openingDate: start,
        ),
    ]);
    final withdrawal = TransactionModel(
      id: 'w',
      description: 'Cash withdrawal',
      amount: 1000,
      type: TransactionType.transfer,
      categoryId: 'transfer',
      date: now,
      account: Account.mpesa,
      toAccount: Account.cash,
      accountId: 'mpesa-sim1',
      toAccountId: 'cash',
      fee: 29,
    );
    final repo = await pumpApp(tester,
        repository: FakeTransactionRepository([withdrawal]),
        accounts: accounts);
    Future<void> cardShows(String amount) async {
      await tester.scrollUntilVisible(find.text(amount), 150,
          scrollable: find
              .descendant(
                  of: find.byType(AccountCards),
                  matching: find.byType(Scrollable))
              .first);
      expect(find.text(amount), findsOneWidget);
    }

    // SIM 1: 1,500 - 1,029; Cash: 300 + 1,000.
    await cardShows('KSh 471.00');
    await cardShows('KSh 1,300.00');
    await tester.drag(find.byType(AccountCards), const Offset(2000, 0));
    await tester.pumpAndSettle();

    await longPress(tester, 'Cash withdrawal');
    await chooseDelete(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(repo.items, isEmpty);
    await scrollToTop(tester);
    await tester.drag(find.byType(AccountCards), const Offset(2000, 0));
    await tester.pumpAndSettle();
    await cardShows('KSh 1,500.00');
    expect(find.text('KSh 471.00'), findsNothing);
    await cardShows('KSh 300.00');
  });

  testWidgets('a deleted SMS transaction is not imported again',
      (tester) async {
    phone(tester);
    final gateway = FakeSmsGateway(permissionGranted: true);
    final repo = await pumpApp(tester,
        repository: FakeTransactionRepository(),
        sms: gateway,
        smsSettings: FakeSmsSettings(enabled: true, last: now));
    final message = RawSms(
      sender: 'MPESA',
      body: 'TJ6AB1CD2E Confirmed. Ksh500.00 paid to NAIVAS. on 6/10/26 at '
          '1:20 PM.New M-PESA balance is Ksh2,700.00.',
      date: now,
    );
    gateway.receive(message);
    await tester.pumpAndSettle();
    expect(repo.items, hasLength(1));
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold).first))
        .hideCurrentSnackBar();
    await tester.pumpAndSettle();

    await longPress(tester, 'Naivas');
    await chooseDelete(tester);
    expect(find.textContaining("It won't be added again from its SMS"),
        findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(repo.items, isEmpty);

    gateway.receive(message); // the same SMS again
    await tester.pumpAndSettle();
    expect(repo.items, isEmpty);
  });

  group('Undo', () {
    Future<void> deleteLunch(WidgetTester tester) async {
      await longPress(tester, 'Lunch');
      await chooseDelete(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
    }

    testWidgets('puts the transaction back exactly as it was',
        (tester) async {
      phone(tester);
      final repo = await pumpApp(tester,
          repository: FakeTransactionRepository([lunch, books, salary]));
      await deleteLunch(tester);
      await scrollToTop(tester);
      expect(find.text('KSh 3,800.00'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      final back = repo.items.firstWhere((t) => t.id == 'l');
      expect(back.description, 'Lunch');
      expect(back.amount, 300);
      expect(back.date, lunch.date);
      expect(back.type, lunch.type);
      expect(back.categoryId, lunch.categoryId);
      expect(back.account, lunch.account);
      expect(repo.items, hasLength(3)); // no extra copy
      expect(find.text('Restored "Lunch"'), findsOneWidget);
      expect(find.text('KSh 3,500.00'), findsOneWidget);
    });

    testWidgets('also after deleting from the edit form', (tester) async {
      phone(tester);
      final repo = await pumpApp(tester,
          repository: FakeTransactionRepository([lunch, books]));
      await scrollAndTap(tester, 'Lunch');
      await tester.tap(find.byTooltip('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(repo.items.map((t) => t.id), ['b']);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(repo.items.map((t) => t.id), unorderedEquals(['l', 'b']));
    });

    testWidgets('an SMS transaction comes back under its own code',
        (tester) async {
      phone(tester);
      final sms = TransactionModel(
        id: 'mpesa_TJ6AB1CD2E',
        description: 'Naivas',
        amount: 500,
        type: TransactionType.expense,
        categoryId: 'food',
        date: now,
        source: TransactionSource.mpesa,
        reference: 'TJ6AB1CD2E',
        account: Account.mpesa,
        simSlot: 1,
      );
      final repo =
          await pumpApp(tester, repository: FakeTransactionRepository([sms]));
      await longPress(tester, 'Naivas');
      await chooseDelete(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      final back = repo.items.single;
      expect(back.id, 'mpesa_TJ6AB1CD2E');
      expect(back.reference, 'TJ6AB1CD2E');
      expect(back.simSlot, 1);
      expect(back.isDetected, isTrue);
    });

    testWidgets('a failed undo says so', (tester) async {
      phone(tester);
      final repo = await pumpApp(tester,
          repository: _RejectsRestore([lunch, books]));
      await deleteLunch(tester);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(find.text("Couldn't restore. Check your connection."),
          findsOneWidget);
      expect(find.text('Restored "Lunch"'), findsNothing);
      expect(repo.items.map((t) => t.id), ['b']);
    });
  });
}

/// Deletes work; putting one back is rejected.
class _RejectsRestore extends FakeTransactionRepository {
  _RejectsRestore(super.initial);

  @override
  Future<bool> addDetected(TransactionModel t,
          {required String dedupeKey}) async =>
      throw const DataException("Couldn't restore. Check your connection.");
}
