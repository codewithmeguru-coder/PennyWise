import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/categorization/category_rule.dart';
import 'package:pennywise/categorization/category_suggester.dart';
import 'package:pennywise/models/transaction_model.dart';
import 'package:pennywise/sms/sms_import_service.dart';
import 'package:pennywise/sms/sms_parser.dart';
import 'package:pennywise/sms/sms_transaction.dart';

import 'fake_category_rules.dart';
import 'fake_transaction_repository.dart';
import 'test_app.dart';

// In-memory only: no Firestore record is read or changed.

final day = DateTime.now().subtract(const Duration(hours: 2));

SmsTransaction parse(String body) =>
    SmsParser.parse(sender: 'MPESA', body: body, date: day)!;

String till(String code, String name, String amount) =>
    '$code Confirmed. Ksh$amount paid to $name. on 9/10/26 at 5:05 PM.New '
    'M-PESA balance is Ksh1,200.00. Transaction cost, Ksh0.00.';

String toPerson(String code, String name) =>
    '$code Confirmed. Ksh500.00 sent to $name 0722334455 on 9/10/26 at '
    '5:05 PM. New M-PESA balance is Ksh200.00. Transaction cost, Ksh7.00.';

String bankPaybill(String code) =>
    '$code Confirmed. Ksh2,000.00 sent to IM BANK C2B for account '
    '0123456789 on 9/10/26 at 5:05 PM New M-PESA balance is Ksh900.00. '
    'Transaction cost, Ksh15.00.';

/// The transaction as PennyWise stores it (masked SMS, id = mpesa_<code>).
TransactionModel stored(String body, {String? category, int minutesAgo = 0}) {
  final t = SmsImportService.toTransaction(parse(body));
  return TransactionModel(
    id: 'mpesa_${t.reference}',
    description: t.description,
    amount: t.amount,
    type: t.type,
    categoryId: category ?? t.categoryId,
    date: day.subtract(Duration(minutes: minutesAgo)),
    note: t.note,
    source: t.source,
    reference: t.reference,
    smsText: t.smsText,
    account: t.account,
    fee: t.fee,
  );
}

void main() {
  group('merchant keys', () {
    test('a new SMS and the stored (masked) copy give the same key', () {
      final body = bankPaybill('TJ9AB1CD20');
      final fresh = CategoryRule.keyFor(parse(body));
      final fromStore = CategoryRule.keyForStored(stored(body));
      expect(fresh, 'OUT:IM_BANK_C2B:01XXXXX789');
      expect(fromStore, fresh);
    });

    test('direction is part of the key; manual entries have none', () {
      expect(CategoryRule.keyFor(parse(till('TJ9AB1CD21', 'LILIES SUPERMARKET', '300.00'))),
          'OUT:LILIES_SUPERMARKET');
      expect(
          CategoryRule.keyFor(parse('TJ9AB1CD22 Confirmed.You have received '
              'Ksh900.00 from LILIES SUPERMARKET on 9/10/26 at 5:05 PM New '
              'M-PESA balance is Ksh1,000.00.')),
          'IN:LILIES_SUPERMARKET');
      expect(
          CategoryRule.keyForStored(TransactionModel(
              description: 'Lunch',
              amount: 5,
              type: TransactionType.expense,
              categoryId: 'food',
              date: day)),
          isNull);
    });
  });

  group('suggester uses learned rules first', () {
    final rules = {
      'OUT:MARGARET_NGANGA': const CategoryRule(
          key: 'OUT:MARGARET_NGANGA',
          categoryId: 'family_support',
          type: TransactionType.expense),
      'OUT:IM_BANK_C2B:01XXXXX789': const CategoryRule(
          key: 'OUT:IM_BANK_C2B:01XXXXX789',
          categoryId: 'education',
          type: TransactionType.expense),
      'IN:ZIIDI': const CategoryRule(
          key: 'IN:ZIIDI', categoryId: 'salary', type: TransactionType.income),
    };
    final suggester = CategorySuggester(rules: rules);

    test('a person and a bank Paybill get your earlier choice', () {
      final person = suggester.forSms(parse(toPerson('TJ9AB1CD23', 'MARGARET NGANGA')));
      expect(person.categoryId, 'family_support');
      expect(person.confidence, Confidence.high);
      expect(person.reason, contains('Your earlier choice'));

      final bank = suggester.forSms(parse(bankPaybill('TJ9AB1CD24')));
      expect(bank.categoryId, 'education');
    });

    test('a different account number at the same bank is not matched', () {
      final other = parse(bankPaybill('TJ9AB1CD25').replaceFirst('0123456789', '9988776655'));
      expect(suggester.forSms(other).confidence, Confidence.low);
    });

    test('rules never override savings or transfers', () {
      final ziidi = parse('TJ9AB1CD26 Confirmed.You have received Ksh500.00 '
          'from ZIIDI on 9/10/26 at 5:05 PM. New M-PESA balance is '
          'Ksh600.00.');
      expect(suggester.forSms(ziidi).categoryId, 'savings_withdrawal');
    });

    test('import uses the rule for new SMS', () {
      final t = SmsImportService.toTransaction(
          parse(toPerson('TJ9AB1CD27', 'MARGARET NGANGA')),
          rules: rules);
      expect(t.categoryId, 'family_support');
    });
  });

  group('learning from a correction in the app', () {
    Future<(FakeTransactionRepository, FakeCategoryRuleRepository)> pump(
        WidgetTester tester) async {
      final repo = FakeTransactionRepository([
        stored(till('TJ9AB1CD30', 'MAMA PIMA', '120.00'), minutesAgo: 1),
        stored(till('TJ9AB1CD31', 'MAMA PIMA', '80.00'), minutesAgo: 2),
        stored(till('TJ9AB1CD32', 'MAMA PIMA', '60.00'), minutesAgo: 3),
        // Same merchant, already categorized by the user: not offered.
        stored(till('TJ9AB1CD33', 'MAMA PIMA', '40.00'),
            category: 'entertainment', minutesAgo: 4),
        stored(till('TJ9AB1CD34', 'OKAVA KENYA LTD', '10.00'), minutesAgo: 5),
      ]);
      final rules = FakeCategoryRuleRepository();
      tester.view.physicalSize = const Size(2400, 3000);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await pumpApp(tester, repository: repo, categoryRules: rules);
      await tester.tap(find.byIcon(Icons.receipt_long_outlined));
      await tester.pumpAndSettle();
      return (repo, rules);
    }

    Future<void> recategorize(WidgetTester tester, String category) async {
      await tester.tap(find.text('Mama Pima').first);
      await tester.pumpAndSettle();
      await scrollAndTap(tester, category);
      await scrollAndTap(tester, 'Save changes');
    }

    testWidgets('remembers the choice and asks before changing others',
        (tester) async {
      final (repo, rules) = await pump(tester);
      await recategorize(tester, 'Food');

      expect(rules.rules['OUT:MAMA_PIMA']?.categoryId, 'food');
      expect(rules.rules['OUT:MAMA_PIMA']?.label, 'Mama Pima');
      expect(find.text('Use Food for 2 more?'), findsOneWidget);

      // "Not now": nothing else changes.
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      final cats = {for (final t in repo.items) t.id: t.categoryId};
      expect(cats['mpesa_TJ9AB1CD30'], 'food');
      expect(cats['mpesa_TJ9AB1CD31'], 'uncategorized');
      expect(cats['mpesa_TJ9AB1CD32'], 'uncategorized');
    });

    testWidgets('"Apply" changes only the matching uncategorized ones',
        (tester) async {
      final (repo, _) = await pump(tester);
      await recategorize(tester, 'Food');
      await tester.tap(find.text('Apply to 2'));
      await tester.pumpAndSettle();

      final cats = {for (final t in repo.items) t.id: t.categoryId};
      expect(cats['mpesa_TJ9AB1CD31'], 'food');
      expect(cats['mpesa_TJ9AB1CD32'], 'food');
      expect(cats['mpesa_TJ9AB1CD33'], 'entertainment'); // your own choice
      expect(cats['mpesa_TJ9AB1CD34'], 'uncategorized'); // other merchant
      expect(repo.items, hasLength(5)); // nothing added or removed
    });

    testWidgets('manual entries are never learned from', (tester) async {
      final repo = FakeTransactionRepository(testTransactions());
      final rules = FakeCategoryRuleRepository();
      await pumpApp(tester, repository: repo, categoryRules: rules);
      await tester.tap(find.text('Lunch'));
      await tester.pumpAndSettle();
      await scrollAndTap(tester, 'Shopping');
      await scrollAndTap(tester, 'Save changes');
      expect(rules.rules, isEmpty);
    });

    testWidgets('Settings lists learned categories and can forget one',
        (tester) async {
      final rules = FakeCategoryRuleRepository([
        const CategoryRule(
            key: 'OUT:MAMA_PIMA',
            categoryId: 'food',
            type: TransactionType.expense,
            label: 'Mama Pima'),
      ]);
      await pumpApp(tester, categoryRules: rules);
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Learned categories'));
      await tester.pumpAndSettle();
      expect(find.text('Mama Pima'), findsOneWidget);
      expect(find.text('Money paid → Food'), findsOneWidget);

      await tester.tap(find.byTooltip('Forget'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Forget'));
      await tester.pumpAndSettle();
      expect(rules.rules, isEmpty);
      expect(find.text('Nothing learned yet'), findsOneWidget);
    });
  });
}
