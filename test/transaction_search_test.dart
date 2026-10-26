import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/models/transaction_model.dart';
import 'package:pennywise/utils/transaction_search.dart';

import 'fake_transaction_repository.dart';
import 'test_app.dart';

// In memory only: search never reads Firestore.

final now = DateTime.now();

TransactionModel tx(String id, String description, double amount,
        {String category = 'food',
        TransactionType type = TransactionType.expense,
        String? reference,
        String? note,
        int minutesAgo = 0}) =>
    TransactionModel(
      id: id,
      description: description,
      amount: amount,
      type: type,
      categoryId: category,
      date: now.subtract(Duration(minutes: minutesAgo)),
      account: Account.mpesa,
      reference: reference,
      note: note,
    );

final naivas = tx('n', 'Naivas Westlands', 1000, reference: 'UJMAB1CD31');
final rent = tx('r', 'Rent October', 25000.5, category: 'housing',
    note: 'Paid to landlord', minutesAgo: 10);
final salary = tx('s', 'Salary', 50000,
    category: 'salary', type: TransactionType.income, minutesAgo: 20);

void main() {
  group('matching', () {
    bool m(TransactionModel t, String q) => TransactionSearch.matches(t, q);

    test('empty search matches everything', () {
      expect(m(naivas, ''), isTrue);
      expect(m(naivas, '   '), isTrue);
    });

    test('name, note, category, account and code, ignoring case', () {
      expect(m(naivas, 'naivas'), isTrue);
      expect(m(naivas, 'WEST'), isTrue);
      expect(m(rent, 'landlord'), isTrue);
      expect(m(naivas, 'food'), isTrue); // category name
      expect(m(naivas, 'm-pesa'), isTrue); // account
      expect(m(naivas, 'ujmab1cd31'), isTrue); // transaction code
      expect(m(naivas, 'rent'), isFalse);
    });

    test('amounts with or without commas and cents', () {
      expect(m(naivas, '1000'), isTrue);
      expect(m(naivas, '1,000'), isTrue);
      expect(m(naivas, '1000.00'), isTrue);
      expect(m(rent, '25000.5'), isTrue);
      expect(m(rent, '25,000.50'), isTrue);
      expect(m(naivas, '100'), isFalse); // not part of another amount
    });

    test('every word must match', () {
      expect(m(rent, 'rent 25000.50'), isTrue);
      expect(m(rent, 'rent naivas'), isFalse);
    });

    test('filter keeps the list order', () {
      expect(
          TransactionSearch.filter([naivas, rent, salary], 'a')
              .map((t) => t.id),
          ['n', 'r', 's']);
      expect(TransactionSearch.filter([naivas, rent, salary], 'salary')
          .map((t) => t.id), ['s']);
    });
  });

  group('on the Transactions tab', () {
    void phone(WidgetTester tester) {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.8125;
      addTearDown(tester.view.reset);
    }

    Future<void> openTransactions(WidgetTester tester) async {
      phone(tester);
      await pumpApp(tester,
          repository: FakeTransactionRepository([naivas, rent, salary]));
      await tester.tap(find.text('Transactions'));
      await tester.pumpAndSettle();
    }

    Finder searchBox() => find.byType(TextField);

    testWidgets('typing narrows the list; clearing restores it',
        (tester) async {
      await openTransactions(tester);
      await tester.enterText(searchBox(), 'naivas');
      await tester.pumpAndSettle();
      expect(find.text('Naivas Westlands'), findsOneWidget);
      expect(find.text('Rent October'), findsNothing);

      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(find.text('Rent October'), findsOneWidget);
      expect(find.text('Salary'), findsWidgets);
    });

    testWidgets('search works together with the filter', (tester) async {
      await openTransactions(tester);
      await tester.tap(find.text('Income'));
      await tester.pumpAndSettle();
      await tester.enterText(searchBox(), 'naivas');
      await tester.pumpAndSettle();
      expect(find.text('No transactions match "naivas".'), findsOneWidget);
    });

    testWidgets('search by amount', (tester) async {
      await openTransactions(tester);
      await tester.enterText(searchBox(), '25,000.50');
      await tester.pumpAndSettle();
      expect(find.text('Rent October'), findsOneWidget);
      expect(find.text('Naivas Westlands'), findsNothing);
    });

    testWidgets('Needs review has its own search', (tester) async {
      phone(tester);
      await pumpApp(tester,
          repository: FakeTransactionRepository([
            tx('u1', 'Lilies Supermarket', 250, category: 'uncategorized'),
            tx('u2', 'Mama Pima Stores', 80,
                category: 'uncategorized', minutesAgo: 5),
          ]));
      await tester.tap(find.text('Transactions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Needs review (2)'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'pima');
      await tester.pumpAndSettle();
      expect(find.text('Mama Pima Stores'), findsOneWidget);
      expect(find.text('Lilies Supermarket'), findsNothing);

      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pumpAndSettle();
      expect(find.text('Nothing waiting matches "zzz".'), findsOneWidget);
    });
  });
}
