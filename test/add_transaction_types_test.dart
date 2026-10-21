import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/models/transaction_model.dart';

import 'fake_transaction_repository.dart';
import 'test_app.dart';

Future<void> openForm(WidgetTester tester) async {
  await tester.tap(find.text('Add'));
  await tester.pumpAndSettle();
}

Future<void> fill(WidgetTester tester, String label, String text) =>
    tester.enterText(find.widgetWithText(TextFormField, label), text);

/// Opens the dropdown labelled [label] and picks [option].
Future<void> pick(WidgetTester tester, String label, String option) async {
  await scrollAndTap(tester, label);
  await tester.tap(find.text(option).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a cash withdrawal is saved as a transfer with its fee',
      (tester) async {
    final repo = await pumpApp(tester, repository: FakeTransactionRepository());
    await openForm(tester);

    await tester.tap(find.text('Transfer'));
    await tester.pumpAndSettle();
    expect(find.text('Category'), findsNothing); // fixed category
    await fill(tester, 'Amount', '1000');
    await fill(tester, 'Description', 'Cash withdrawal');
    await pick(tester, 'To account', 'Cash');
    await fill(tester, 'Transaction cost (optional)', '29');
    await scrollAndTap(tester, 'Save transaction');

    final saved = repo.items.single;
    expect(saved.type, TransactionType.transfer);
    expect(saved.categoryId, 'transfer');
    expect(saved.account, Account.mpesa);
    expect(saved.toAccount, Account.cash);
    expect(saved.fee, 29);
  });

  testWidgets('a transfer to the same account is rejected', (tester) async {
    final repo = await pumpApp(tester, repository: FakeTransactionRepository());
    await openForm(tester);

    await tester.tap(find.text('Transfer'));
    await tester.pumpAndSettle();
    await fill(tester, 'Amount', '500');
    await fill(tester, 'Description', 'Oops');
    await pick(tester, 'To account', 'M-Pesa');
    await scrollAndTap(tester, 'Save transaction');

    expect(find.text('Pick a different account'), findsOneWidget);
    expect(repo.items, isEmpty);
  });

  testWidgets('a savings contribution needs no category and is not spending',
      (tester) async {
    final repo = await pumpApp(tester, repository: FakeTransactionRepository());
    await openForm(tester);

    await tester.tap(find.text('To savings'));
    await tester.pumpAndSettle();
    await fill(tester, 'Amount', '5000');
    await fill(tester, 'Description', 'Ziidi');
    await scrollAndTap(tester, 'Save transaction');

    final saved = repo.items.single;
    expect(saved.type, TransactionType.savingsContribution);
    expect(saved.categoryId, 'savings');
    // Dashboard: available drops, savings appears separately.
    expect(find.text('-KSh 5,000.00'), findsOneWidget);
    expect(find.text('Savings KSh 5,000.00'), findsOneWidget);
  });

  testWidgets('a refund picks the category of the purchase it refunds',
      (tester) async {
    final repo = await pumpApp(tester, repository: FakeTransactionRepository());
    await openForm(tester);

    await tester.tap(find.text('Refund'));
    await tester.pumpAndSettle();
    expect(find.text('Category of the purchase refunded'), findsOneWidget);
    await fill(tester, 'Amount', '450');
    await fill(tester, 'Description', 'Returned shoes');
    await scrollAndTap(tester, 'Shopping');
    await scrollAndTap(tester, 'Save transaction');

    final saved = repo.items.single;
    expect(saved.type, TransactionType.refund);
    expect(saved.categoryId, 'shopping');
  });

  testWidgets('debt interest above the repayment is rejected', (tester) async {
    final repo = await pumpApp(tester, repository: FakeTransactionRepository());
    await openForm(tester);

    await tester.tap(find.text('Debt repayment'));
    await tester.pumpAndSettle();
    await fill(tester, 'Amount', '100');
    await fill(tester, 'Description', 'Fuliza');
    await fill(tester, 'Interest or charges included (optional)', '150');
    await scrollAndTap(tester, 'Save transaction');

    expect(find.text("Can't be more than the amount repaid"), findsOneWidget);
    expect(repo.items, isEmpty);
  });

  testWidgets('editing an older entry without an account keeps "Not set"',
      (tester) async {
    final repo = await pumpApp(tester,
        repository: FakeTransactionRepository(testTransactions()));

    await tester.tap(find.text('Lunch'));
    await tester.pumpAndSettle();
    expect(find.text('Not set'), findsOneWidget);
    await scrollAndTap(tester, 'Save changes');

    final lunch = repo.items.firstWhere((t) => t.id == 't1');
    expect(lunch.account, isNull);
    expect(lunch.type, TransactionType.expense);
  });
}
