import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/models/ledger.dart';
import 'package:pennywise/models/transaction_category.dart';
import 'package:pennywise/models/transaction_model.dart';

import 'fake_transaction_repository.dart';
import 'test_app.dart';

// Everything here runs on in-memory data (FakeTransactionRepository); no
// Firestore record is read, created or changed.

final today = DateTime.now();
final noon = DateTime(today.year, today.month, today.day, 12);

TransactionModel entry(
  String id,
  String description,
  TransactionType type,
  double amount, {
  String? category,
  Account? account = Account.mpesa,
  Account? toAccount,
  int minutesAgo = 0,
}) =>
    TransactionModel(
      id: id,
      description: description,
      amount: amount,
      type: type,
      categoryId: category ??
          (DefaultCategories.hasFixedCategory(type)
              ? DefaultCategories.fixedCategoryFor(type)
              : 'food'),
      date: noon.subtract(Duration(minutes: minutesAgo)),
      account: account,
      toAccount: toAccount,
    );

Future<void> openForm(WidgetTester tester) async {
  await tester.tap(find.text('Add'));
  await tester.pumpAndSettle();
}

Future<void> fill(WidgetTester tester, String label, String text) =>
    tester.enterText(find.widgetWithText(TextFormField, label), text);

void main() {
  group('category lists', () {
    test('new entries cannot pick the old cash categories', () {
      final expense = DefaultCategories.forType(TransactionType.expense)
          .map((c) => c.id);
      final income =
          DefaultCategories.forType(TransactionType.income).map((c) => c.id);

      expect(expense, isNot(contains('cash_withdrawal')));
      expect(income, isNot(contains('cash_deposit')));
    });

    test('an older entry keeps showing its cash category', () {
      final expense = DefaultCategories.forType(TransactionType.expense,
              keep: 'cash_withdrawal')
          .map((c) => c.id);

      expect(expense, contains('cash_withdrawal'));
      expect(DefaultCategories.byId('cash_withdrawal').name, 'Cash withdrawal');
      expect(DefaultCategories.byId('cash_deposit').name, 'Cash deposit');
    });
  });

  group('shortcuts', () {
    testWidgets('Cash withdrawal saves a transfer M-Pesa → Cash with its fee',
        (tester) async {
      final repo =
          await pumpApp(tester, repository: FakeTransactionRepository());
      await openForm(tester);

      expect(find.text('Cash withdrawal'), findsNothing); // no expense chip
      await fill(tester, 'Amount', '1000');
      await scrollAndTap(tester, 'Cash withdrawal → Transfer');
      await fill(tester, 'Transaction cost (optional)', '29');
      await scrollAndTap(tester, 'Save transaction');

      final saved = repo.items.single;
      expect(saved.type, TransactionType.transfer);
      expect(saved.categoryId, 'transfer');
      expect(saved.description, 'Cash withdrawal');
      expect(saved.account, Account.mpesa);
      expect(saved.toAccount, Account.cash);
      expect(saved.amount, 1000);
      expect(saved.fee, 29);

      // Only the fee is spending; the 1,000 just moved into Cash.
      final ledger = Ledger.of(repo.items);
      expect(ledger.spending, 29);
      expect(ledger.income, 0);
      expect(ledger.balanceOf(Account.mpesa), -1029);
      expect(ledger.balanceOf(Account.cash), 1000);
      expect(ledger.available, -29);
      // The dashboard shows the same: available down by the fee only.
      expect(find.text('-KSh 29.00'), findsWidgets);
    });

    testWidgets('Cash deposit saves a transfer Cash → M-Pesa, not income',
        (tester) async {
      final repo =
          await pumpApp(tester, repository: FakeTransactionRepository());
      await openForm(tester);

      await tester.tap(find.text('Income'));
      await tester.pumpAndSettle();
      expect(find.text('Cash deposit'), findsNothing); // no income chip
      await fill(tester, 'Amount', '2500');
      await scrollAndTap(tester, 'Cash deposit → Transfer');
      await scrollAndTap(tester, 'Save transaction');

      final saved = repo.items.single;
      expect(saved.type, TransactionType.transfer);
      expect(saved.description, 'Cash deposit');
      expect(saved.account, Account.cash);
      expect(saved.toAccount, Account.mpesa);
      expect(saved.fee, isNull);

      final ledger = Ledger.of(repo.items);
      expect(ledger.income, 0);
      expect(ledger.spending, 0);
      expect(ledger.available, 0);
      expect(ledger.balanceOf(Account.mpesa), 2500);
    });

    testWidgets('the shortcut keeps a description the user already typed',
        (tester) async {
      final repo =
          await pumpApp(tester, repository: FakeTransactionRepository());
      await openForm(tester);

      await fill(tester, 'Amount', '500');
      await fill(tester, 'Description', 'ATM at Sarit');
      await scrollAndTap(tester, 'Cash withdrawal → Transfer');
      await scrollAndTap(tester, 'Save transaction');

      expect(repo.items.single.description, 'ATM at Sarit');
    });
  });

  group('an older cash-withdrawal expense', () {
    FakeTransactionRepository withOldWithdrawal() => FakeTransactionRepository([
          entry('old', 'Withdrawal', TransactionType.expense, 1000,
              category: 'cash_withdrawal'),
        ]);

    testWidgets('stays an expense when saved unchanged', (tester) async {
      final repo = await pumpApp(tester, repository: withOldWithdrawal());

      await tester.tap(find.text('Withdrawal'));
      await tester.pumpAndSettle();
      // Its category is still shown and selected.
      final chip = tester.widget<ChoiceChip>(
          find.widgetWithText(ChoiceChip, 'Cash withdrawal'));
      expect(chip.selected, isTrue);
      await scrollAndTap(tester, 'Save changes');

      final saved = repo.items.single;
      expect(saved.type, TransactionType.expense);
      expect(saved.categoryId, 'cash_withdrawal');
    });

    testWidgets('can be converted in place into a transfer, without a copy',
        (tester) async {
      final repo = await pumpApp(tester, repository: withOldWithdrawal());

      await tester.tap(find.text('Withdrawal'));
      await tester.pumpAndSettle();
      await scrollAndTap(tester, 'Cash withdrawal → Transfer');
      await scrollAndTap(tester, 'Save changes');

      expect(repo.items, hasLength(1)); // updated, not duplicated
      final saved = repo.items.single;
      expect(saved.id, 'old');
      expect(saved.type, TransactionType.transfer);
      expect(saved.description, 'Withdrawal'); // kept
      expect(saved.amount, 1000);
      expect(saved.account, Account.mpesa);
      expect(saved.toAccount, Account.cash);
      expect(Ledger.of(repo.items).spending, 0);
    });
  });

  testWidgets('Transfers filter: transfers and savings, not old cash expenses',
      (tester) async {
    await pumpApp(tester,
        repository: FakeTransactionRepository([
          entry('t', 'To cash', TransactionType.transfer, 1000,
              toAccount: Account.cash, minutesAgo: 1),
          entry('s', 'To Ziidi', TransactionType.savingsContribution, 500,
              minutesAgo: 2),
          entry('w', 'From Ziidi', TransactionType.savingsWithdrawal, 200,
              minutesAgo: 3),
          entry('old', 'Old withdrawal', TransactionType.expense, 300,
              category: 'cash_withdrawal', minutesAgo: 4),
          entry('lunch', 'Lunch', TransactionType.expense, 250, minutesAgo: 5),
        ]));

    await tester.tap(find.byIcon(Icons.receipt_long_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Transfers'));
    await tester.pumpAndSettle();

    expect(find.text('To cash'), findsOneWidget);
    expect(find.text('To Ziidi'), findsOneWidget);
    expect(find.text('From Ziidi'), findsOneWidget);
    expect(find.text('Old withdrawal'), findsNothing);
    expect(find.text('Lunch'), findsNothing);

    await tester.tap(find.text('Expenses'));
    await tester.pumpAndSettle();
    expect(find.text('Old withdrawal'), findsOneWidget);
    expect(find.text('Lunch'), findsOneWidget);
    expect(find.text('To cash'), findsNothing);
  });

  test('old cash-withdrawal expenses keep counting as spending', () {
    final ledger = Ledger.of([
      entry('old', 'Withdrawal', TransactionType.expense, 1000,
          category: 'cash_withdrawal'),
    ]);

    expect(ledger.spending, 1000);
    expect(ledger.categoryCents['cash_withdrawal'], 100000);
  });
}
