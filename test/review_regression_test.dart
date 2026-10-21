import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/models/budget_model.dart';
import 'package:pennywise/models/monthly_summary.dart';
import 'package:pennywise/models/transaction_model.dart';
import 'package:pennywise/utils/validators.dart';

import 'fake_auth_service.dart';
import 'test_app.dart';

/// Regression tests for issues found in the code review.
void main() {
  group('amount validator messages', () {
    test('rejects non-numbers with a clear message', () {
      for (final input in ['-5', '1e3', 'abc', '1,000', 'NaN', 'Infinity']) {
        expect(Validators.amount(input), 'Enter a valid amount',
            reason: input);
      }
    });

    test('accepts common valid forms', () {
      for (final input in ['5', '5.5', '5.50', '0.01', '.5', '10.']) {
        expect(Validators.amount(input), isNull, reason: input);
      }
    });

    test('keeps the specific messages', () {
      expect(Validators.amount(''), 'Enter an amount');
      expect(Validators.amount('   '), 'Enter an amount');
      expect(Validators.amount('0'), 'Amount must be greater than 0');
      expect(Validators.amount('10.999'), 'Use at most 2 decimal places');
      expect(Validators.amount('1000000000'), 'Amount is too large');
    });
  });

  test('sub-cent amounts from other clients do not produce NaN shares', () {
    final summary = MonthlySummary.calculate(
      month: DateTime(2026, 9),
      transactions: [
        TransactionModel(
          description: 'x',
          amount: 0.001, // allowed by the rules, rounds to 0 cents
          type: TransactionType.expense,
          categoryId: 'food',
          date: DateTime(2026, 9, 5),
        ),
      ],
      budget: 100,
    );

    for (final c in summary.byCategory) {
      expect(c.share.isNaN, isFalse);
    }
  });

  test('text length is measured like the security rules (UTF-16 units)', () {
    String? description(String v) =>
        Validators.requiredText(v, emptyMessage: 'empty', max: 100);

    expect(description('a' * 100), isNull);
    expect(description('é' * 100), isNull); // é: 1 unit each
    // 👍 is 1 visible character but 2 UTF-16 units; the rules count units.
    expect(description('\u{1F44D}' * 50), isNull); // 100 units
    expect(description('\u{1F44D}' * 51), 'Too long, please shorten it');
    expect(description('   '), 'empty');
    expect(Validators.optionalText('', max: 500), isNull);
  });

  testWidgets('ending the session closes a form left open', (tester) async {
    final auth = FakeAuthService(signedInAs: FakeAuthService.testUser);
    await pumpApp(tester, auth: auth);

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.text('Add transaction'), findsOneWidget);

    // e.g. the account was disabled, or signed out on another screen.
    await auth.signOut();
    await tester.pumpAndSettle();

    expect(find.text('Add transaction'), findsNothing);
    expect(find.text('Welcome back'), findsOneWidget);
  });

  test('BudgetModel id ignores the day', () {
    expect(BudgetModel.idFor(DateTime(2026, 9, 30, 23, 59)), '2026-09');
  });
}
