import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/data/data_exception.dart';
import 'package:pennywise/data/transaction_store.dart';
import 'package:pennywise/models/transaction_model.dart';
import 'package:pennywise/screens/needs_review_screen.dart';
import 'package:pennywise/sms/sms_import_service.dart';
import 'package:pennywise/sms/sms_parser.dart';

import 'fake_category_rules.dart';
import 'fake_transaction_repository.dart';
import 'test_app.dart';

// In memory only: no Firestore record is read or changed.

final now = DateTime.now();

String till(String code, String name) =>
    '$code Confirmed. Ksh250.00 paid to $name. on 9/10/26 at 5:05 PM.New '
    'M-PESA balance is Ksh1,200.00. Transaction cost, Ksh5.00.';

String received(String code, String name) =>
    '$code Confirmed.You have received Ksh900.00 from $name 0712345678 on '
    '9/10/26 at 5:05 PM New M-PESA balance is Ksh2,100.00.';

/// A transaction as an SMS import stores it, on SIM 1, [minutesAgo] old.
TransactionModel detected(String body,
    {required String category, required int minutesAgo}) {
  final t = SmsImportService.toTransaction(
      SmsParser.parse(sender: 'MPESA', body: body, date: now)!);
  return TransactionModel(
    id: 'mpesa_${t.reference}',
    description: t.description,
    amount: t.amount,
    type: t.type,
    categoryId: category,
    date: now.subtract(Duration(minutes: minutesAgo)),
    note: t.note,
    source: t.source,
    reference: t.reference,
    smsText: t.smsText,
    account: t.account,
    fee: 5,
    accountId: 'mpesa-sim1',
    simSlot: 0,
  );
}

final shopA = detected(till('TJ1AB1CD01', 'LILIES SUPERMARKET'),
    category: 'uncategorized', minutesAgo: 30);
final shopA2 = detected(till('TJ1AB1CD02', 'LILIES SUPERMARKET'),
    category: 'uncategorized', minutesAgo: 90);
final otherShop = detected(till('TJ1AB1CD03', 'MAMA PIMA STORES'),
    category: 'uncategorized', minutesAgo: 60);
final income = detected(received('TJ1AB1CD04', 'JOHN DOE'),
    category: 'uncategorized_income', minutesAgo: 10);
final categorized = detected(till('TJ1AB1CD05', 'NAIVAS'),
    category: 'food', minutesAgo: 5);

TransactionModel byId(FakeTransactionRepository repo, String id) =>
    repo.items.firstWhere((t) => t.id == id);

/// Everything except the category is unchanged.
void expectSameMoney(TransactionModel after, TransactionModel before) {
  expect(after.id, before.id);
  expect(after.amount, before.amount);
  expect(after.date, before.date);
  expect(after.type, before.type);
  expect(after.fee, before.fee);
  expect(after.account, before.account);
  expect(after.accountId, before.accountId);
  expect(after.simSlot, before.simSlot);
  expect(after.reference, before.reference);
  expect(after.description, before.description);
}

Future<void> openNeedsReview(WidgetTester tester, String label) async {
  await tester.tap(find.text('Transactions'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

Future<void> pickCategory(
    WidgetTester tester, TransactionModel t, String category) async {
  // Same-sender rows share a description; the newest is listed first.
  await tester.tap(find.text(t.description).first);
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(ActionChip, category));
  await tester.pumpAndSettle();
}

/// Never delivers any transactions (stays "loading").
class _NeverLoads extends FakeTransactionRepository {
  @override
  Stream<List<TransactionModel>> watchAll() =>
      StreamController<List<TransactionModel>>().stream;
}

/// Every save is rejected.
class _RejectsSaves extends FakeTransactionRepository {
  _RejectsSaves(super.initial);

  @override
  Future<void> update(TransactionModel t) async =>
      throw const DataException('No connection. Your change wasn\'t saved.');
}

void main() {
  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.8125;
    addTearDown(tester.view.reset);
  }

  testWidgets('lists uncategorized expenses and income, newest first, and '
      'nothing else', (tester) async {
    phone(tester);
    await pumpApp(tester,
        repository: FakeTransactionRepository(
            [shopA, otherShop, income, categorized]));
    await openNeedsReview(tester, 'Needs review (3)');

    expect(find.text('Needs review'), findsOneWidget);
    for (final t in [income, shopA, otherShop]) {
      expect(find.text(t.description), findsOneWidget);
    }
    expect(find.text(categorized.description), findsNothing);
    final y = [
      for (final t in [income, shopA, otherShop])
        tester.getTopLeft(find.text(t.description)).dy,
    ];
    expect(y[0], lessThan(y[1]));
    expect(y[1], lessThan(y[2]));
  });

  testWidgets('fixing one changes only its category, and the count follows',
      (tester) async {
    phone(tester);
    final repo =
        FakeTransactionRepository([shopA, otherShop, income, categorized]);
    await pumpApp(tester, repository: repo);
    await openNeedsReview(tester, 'Needs review (3)');

    // Income only offers income categories.
    await tester.tap(find.text(income.description));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ActionChip, 'Salary'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'Food'), findsNothing);
    expect(find.widgetWithText(ActionChip, 'Uncategorized income'),
        findsNothing);
    await tester.tap(find.widgetWithText(ActionChip, 'Salary'));
    await tester.pumpAndSettle();

    expect(repo.items, hasLength(4)); // updated, not added
    final saved = byId(repo, income.id);
    expect(saved.categoryId, 'salary');
    expectSameMoney(saved, income);
    expect(find.text(income.description), findsNothing); // off the list

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Needs review (2)'), findsOneWidget);
  });

  testWidgets('learning: the sender is remembered; others change only after '
      '"Not now" / "Apply" is chosen', (tester) async {
    phone(tester);
    final repo = FakeTransactionRepository([shopA, shopA2, otherShop]);
    final rules = FakeCategoryRuleRepository();
    await pumpApp(tester, repository: repo, categoryRules: rules);
    await openNeedsReview(tester, 'Needs review (3)');

    await pickCategory(tester, shopA, 'Food');
    expect(byId(repo, shopA.id).categoryId, 'food');
    expect(rules.rules['OUT:LILIES_SUPERMARKET']?.categoryId, 'food');
    // Asked first; nothing else has changed yet.
    expect(find.text('Use Food for 1 more?'), findsOneWidget);
    expect(byId(repo, shopA2.id).categoryId, 'uncategorized');

    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(byId(repo, shopA2.id).categoryId, 'uncategorized');
    expect(byId(repo, otherShop.id).categoryId, 'uncategorized');
    expectSameMoney(byId(repo, shopA.id), shopA);
  });

  testWidgets('"Apply" changes only the same sender\'s uncategorized ones',
      (tester) async {
    phone(tester);
    final repo = FakeTransactionRepository([shopA, shopA2, otherShop]);
    await pumpApp(tester,
        repository: repo, categoryRules: FakeCategoryRuleRepository());
    await openNeedsReview(tester, 'Needs review (3)');

    await pickCategory(tester, shopA, 'Food');
    await tester.tap(find.text('Apply to 1'));
    await tester.pumpAndSettle();

    expect(byId(repo, shopA2.id).categoryId, 'food');
    expectSameMoney(byId(repo, shopA2.id), shopA2);
    expect(byId(repo, otherShop.id).categoryId, 'uncategorized');
    expect(repo.items, hasLength(3));
    expect(find.text(otherShop.description), findsOneWidget);
    expect(find.text(shopA2.description), findsNothing);
  });

  testWidgets('a rejected save keeps the transaction on the list',
      (tester) async {
    phone(tester);
    final repo = _RejectsSaves([shopA]);
    await pumpApp(tester, repository: repo);
    await openNeedsReview(tester, 'Needs review (1)');

    await pickCategory(tester, shopA, 'Food');
    expect(find.text('No connection. Your change wasn\'t saved.'),
        findsOneWidget);
    expect(byId(repo, shopA.id).categoryId, 'uncategorized');
    expect(find.text(shopA.description), findsOneWidget);
  });

  testWidgets('no button when nothing needs review', (tester) async {
    phone(tester);
    await pumpApp(tester,
        repository: FakeTransactionRepository([categorized]));
    await tester.tap(find.text('Transactions'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Needs review'), findsNothing);
  });

  group('the screen on its own', () {
    Future<void> show(WidgetTester tester, FakeTransactionRepository repo,
        {bool settle = true}) async {
      await tester.pumpWidget(MaterialApp(
        home: NeedsReviewScreen(
          store: TransactionStore(repo),
          onCorrect: (_, _) async {},
        ),
      ));
      if (settle) {
        await tester.pumpAndSettle();
      } else {
        await tester.pump();
      }
    }

    testWidgets('empty state', (tester) async {
      await show(tester, FakeTransactionRepository([categorized]));
      expect(find.text('All caught up'), findsOneWidget);
    });

    testWidgets('loading state', (tester) async {
      await show(tester, _NeverLoads(), settle: false);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('load error, with Retry', (tester) async {
      await show(
          tester,
          FakeTransactionRepository()
            ..loadError = const DataException('You are offline.'));
      expect(find.text('Couldn\'t load transactions'), findsOneWidget);
      expect(find.text('You are offline.'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });
  });

  test('only the two uncategorized categories need review', () {
    expect(NeedsReviewScreen.needsReview(shopA), isTrue);
    expect(NeedsReviewScreen.needsReview(income), isTrue);
    expect(NeedsReviewScreen.needsReview(categorized), isFalse);
    expect(
        NeedsReviewScreen.pending([otherShop, categorized, shopA, income])
            .map((t) => t.id),
        [income.id, shopA.id, otherShop.id]);
  });
}
