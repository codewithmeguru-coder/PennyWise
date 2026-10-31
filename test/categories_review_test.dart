import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/accounts/account_repository.dart';
import 'package:pennywise/accounts/money_account.dart';
import 'package:pennywise/categorization/category_registry.dart';
import 'package:pennywise/data/transaction_store.dart';
import 'package:pennywise/maintenance/review_reasons.dart';
import 'package:pennywise/models/custom_category.dart';
import 'package:pennywise/models/transaction_category.dart';
import 'package:pennywise/models/transaction_model.dart';
import 'package:pennywise/screens/categories_screen.dart';
import 'package:pennywise/screens/needs_review_screen.dart';
import 'package:pennywise/sms/sms_import_service.dart';
import 'package:pennywise/sms/sms_parser.dart';

import 'fake_accounts.dart';
import 'fake_category_repository.dart';
import 'fake_sms.dart';
import 'fake_transaction_repository.dart';

// Deleting your own categories safely, clearer SMS descriptions, and
// Needs review saying why. Names, numbers and codes are made up.

const pets = CustomCategory(
  id: 'c_petsabcdef',
  name: 'Pets',
  type: TransactionType.expense,
);

TransactionModel spend(String id, String category) => TransactionModel(
  id: id,
  description: 'Item $id',
  amount: 100,
  type: TransactionType.expense,
  categoryId: category,
  date: DateTime(2026, 10, 5, 10),
  account: Account.mpesa,
);

String describe(String body, {String sender = 'MPESA'}) =>
    SmsImportService.toTransaction(
      SmsParser.parse(sender: sender, body: body, date: DateTime(2026, 10, 9))!,
    ).description;

void main() {
  tearDown(DefaultCategories.clearCustom);

  group('deleting your own category', () {
    late FakeCategoryRepository cats;
    late FakeTransactionRepository txs;

    Future<void> show(WidgetTester tester, List<TransactionModel> items) async {
      cats = FakeCategoryRepository([pets]);
      txs = FakeTransactionRepository(items);
      final registry = CategoryRegistry(cats);
      await tester.pumpWidget(
        MaterialApp(
          home: CategoriesScreen(
            registry: registry,
            transactions: TransactionStore(txs),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pets'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('delete-category')));
      await tester.pumpAndSettle();
    }

    testWidgets('unused: asks once, then it is gone from what can be picked',
        (tester) async {
      await show(tester, [spend('a', 'food')]);
      expect(find.text('Delete "Pets"?'), findsOneWidget);
      expect(find.textContaining('No transactions use it'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-delete-category')));
      await tester.pumpAndSettle();
      expect(find.text('"Pets" deleted'), findsOneWidget);
      expect(
        DefaultCategories.forType(TransactionType.expense).map((c) => c.id),
        isNot(contains(pets.id)),
      );
      expect(txs.items.single.categoryId, 'food'); // untouched
    });

    testWidgets('used: its transactions move to the category you pick first; '
        'nothing is left without one', (tester) async {
      await show(tester, [
        spend('a', pets.id),
        spend('b', pets.id),
        spend('c', 'food'),
      ]);
      expect(find.textContaining('2 transactions use "Pets"'), findsOneWidget);
      await tester.tap(find.byKey(const Key('move-to-shopping')));
      await tester.pumpAndSettle();
      expect(find.textContaining('move to "Shopping"'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-delete-category')));
      await tester.pumpAndSettle();
      final byId = {for (final t in txs.items) t.id: t};
      expect(byId['a']!.categoryId, 'shopping');
      expect(byId['b']!.categoryId, 'shopping');
      expect(byId['c']!.categoryId, 'food');
      // Only the category changed.
      expect([byId['a']!.amount, byId['a']!.description], [100, 'Item a']);
      expect(find.textContaining('2 moved to "Shopping"'), findsOneWidget);
    });

    testWidgets('cancelling the move changes nothing', (tester) async {
      await show(tester, [spend('a', pets.id)]);
      await tester.tapAt(const Offset(10, 10)); // dismiss the sheet
      await tester.pumpAndSettle();
      expect(txs.items.single.categoryId, pets.id);
      expect(cats.writes, isEmpty);
    });
  });

  test('"Airtime, Data & Minutes": exact name, same id, so old records '
      'show it', () {
    expect(DefaultCategories.byId('airtime_data').name,
        'Airtime, Data & Minutes');
  });

  group('descriptions from the SMS', () {
    test('a Paybill names the account paid, masked', () {
      expect(
        describe(
          'TJ6AB1CDP1 Confirmed. Ksh1,200.00 sent to KPLC PREPAID for account '
          '54321098765 on 6/10/26 at 9:01 AM New M-PESA balance is Ksh0.00. '
          'Transaction cost, Ksh0.00.',
        ),
        'Kplc Prepaid · account 54******765',
      );
    });

    test('airtime for another number names it, masked; for yourself it '
        'stays "Airtime"', () {
      expect(
        describe(
          'TJ6AB1CDA1 confirmed.You bought Ksh50.00 of airtime for '
          '254712345678 on 9/10/26 at 8:00 AM.New M-PESA balance is '
          'Ksh10.00.',
        ),
        'Airtime for 25*******678',
      );
      expect(
        describe(
          'TJ6AB1CDA2 confirmed.You bought Ksh50.00 of airtime on 9/10/26 at '
          '8:00 AM.New M-PESA balance is Ksh10.00.',
        ),
        'Airtime',
      );
    });

    test('Equity: by card, and money in via M-Pesa', () {
      expect(
        describe(
          'CONFIRMED. KES 1,250.00, Auth for card 4111..1111 at JAVA HOUSE on '
          '2026-10-20 13:05:00 Ref:223456789012.',
          sender: 'Equity Bank',
        ),
        'Card: Java House',
      );
      expect(
        describe(
          'Confirmed. KES. 700.00 from JOHN OTIENO Phone No. 254700000000 '
          'received via M-Pesa Ref. UCC0000001 on 12-03-2026 at 15:35.',
          sender: 'Equity Bank',
        ),
        'From John Otieno via M-Pesa',
      );
    });
  });

  group('why it needs review', () {
    late AccountStore accounts;
    setUp(() async {
      accounts = AccountStore(FakeAccountRepository(MoneyAccount.starterSet()));
      await Future<void>.delayed(Duration.zero);
    });

    TransactionModel sms(String id, TransactionType type, {int? sim}) =>
        TransactionModel(
          id: id,
          description: 'x',
          amount: 50,
          type: type,
          categoryId: 'food',
          date: DateTime(2026, 10, 6),
          source: TransactionSource.mpesa,
          reference: id,
          smsText: 'x',
          simSlot: sim,
        );

    test('no SIM in the message: says so, and nothing is guessed', () {
      expect(
        ReviewReasons.account(sms('m1', TransactionType.expense), accounts),
        contains("doesn't say which SIM"),
      );
    });

    test('SIM known: names the account it would go on', () {
      expect(
        ReviewReasons.account(
          sms('m2', TransactionType.expense, sim: 1),
          accounts,
        ),
        contains('SIM 2'),
      );
    });

    test('a Ziidi deposit with its SIM: both sides are known', () {
      expect(
        ReviewReasons.account(
          sms('m3', TransactionType.savingsContribution, sim: 0),
          accounts,
        ),
        'A move between your accounts on SIM 1: tap to set both.',
      );
    });

    test('a category the message didn\'t make clear', () {
      expect(
        ReviewReasons.category(sms('m4', TransactionType.expense)),
        contains('remembers it for this sender'),
      );
    });

    testWidgets('each item shows its reason; held messages can be retried',
        (tester) async {
      final settings = FakeSmsSettings(enabled: true, last: DateTime.now());
      settings.skipped[SkipReason.foreignCurrency] = {'equity_CARD1'};
      final service = SmsImportService(
        gateway: FakeSmsGateway(permissionGranted: true),
        settings: settings,
        save: (t, key) async => true,
      );
      await service.start();
      final store = TransactionStore(
        FakeTransactionRepository([
          sms('m5', TransactionType.expense).withCategory('uncategorized'),
        ]),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: NeedsReviewScreen(
            store: store,
            onCorrect: (t, c) async {},
            smsService: service,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reason-m5')), findsOneWidget);
      expect(find.byKey(const Key('held-messages')), findsOneWidget);
      expect(find.textContaining('waiting for that day'), findsOneWidget);
      await tester.tap(find.byKey(const Key('retry-held')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Nothing could be added yet'), findsOneWidget);
    });
  });
}
