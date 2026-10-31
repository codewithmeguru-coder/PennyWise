import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/models/transaction_model.dart';
import 'package:pennywise/privacy/savings_privacy.dart';

import 'fake_transaction_repository.dart';
import 'test_app.dart';

// "Hide savings amounts": savings show as KSh •••• until the eye is
// tapped. Amounts are made up.

final now = DateTime.now();

TransactionModel tx(String id, TransactionType type, double amount,
        {String category = 'food', String? description}) =>
    TransactionModel(
      id: id,
      description: description ?? id,
      amount: amount,
      type: type,
      categoryId: category,
      date: now.subtract(const Duration(hours: 1)),
      account: Account.mpesa,
    );

List<TransactionModel> data() => [
  tx('pay', TransactionType.income, 10000, category: 'salary'),
  tx('ziidi', TransactionType.savingsContribution, 4321,
      category: 'savings', description: 'Ziidi deposit'),
  tx('lunch', TransactionType.expense, 250),
];

void phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
}

void main() {
  group('hide savings amounts', () {
    String savingsLine(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const Key('balance-savings'))).data!;

    testWidgets('on by default: masked on Home, the eye reveals, leaving '
        'the app hides again', (tester) async {
      phone(tester);
      final privacy = SavingsPrivacyController(
        store: MemorySavingsPrivacyStore(),
      );
      await pumpApp(
        tester,
        repository: FakeTransactionRepository(data()),
        savingsPrivacy: privacy,
      );
      expect(privacy.enabled, isTrue);
      expect(savingsLine(tester), 'Savings KSh ••••');
      expect(find.textContaining('4,321'), findsNothing);
      await tester.tap(find.byKey(const Key('savings-eye')));
      await tester.pumpAndSettle();
      expect(savingsLine(tester), 'Savings KSh 4,321.00');
      expect(find.textContaining('4,321.00'), findsWidgets);

      privacy.didChangeAppLifecycleState(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      expect(savingsLine(tester), 'Savings KSh ••••');

      // The Ziidi deposit in Recent is masked; spending is not.
      await tester.scrollUntilVisible(
        find.text('Ziidi deposit'),
        300,
        scrollable: find.byType(Scrollable).hitTestable().first,
      );
      expect(
        find.descendant(
          of: find.ancestor(
            of: find.text('Ziidi deposit'),
            matching: find.byType(ListTile),
          ),
          matching: find.text('KSh ••••'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('250.00'), findsWidgets);
    });

    testWidgets('turned off in Settings: amounts show and no eye; the choice '
        'is saved', (tester) async {
      phone(tester);
      final store = MemorySavingsPrivacyStore();
      final privacy = SavingsPrivacyController(store: store);
      await pumpApp(
        tester,
        repository: FakeTransactionRepository(data()),
        savingsPrivacy: privacy,
      );
      await tester.tap(find.byTooltip('Settings').first);
      await tester.pumpAndSettle();
      final toggle = find.byKey(const Key('hide-savings-switch'));
      await tester.scrollUntilVisible(
        toggle,
        300,
        scrollable: find.byType(Scrollable).hitTestable().first,
      );
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(store.saved, isFalse);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(savingsLine(tester), 'Savings KSh 4,321.00');
      expect(find.byKey(const Key('savings-eye')), findsNothing);
    });

    test('remembered across restarts', () async {
      final store = MemorySavingsPrivacyStore(false);
      final privacy = SavingsPrivacyController(store: store);
      TestWidgetsFlutterBinding.ensureInitialized();
      await privacy.init();
      expect(privacy.enabled, isFalse);
      expect(privacy.hidden, isFalse);
      privacy.dispose();
    });
  });
}
