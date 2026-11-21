import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/accounts/account_balances.dart';
import 'package:pennywise/accounts/loan_limit.dart';
import 'package:pennywise/accounts/money_account.dart';
import 'package:pennywise/screens/accounts_screen.dart';
import 'package:pennywise/theme/app_theme.dart';
import 'package:pennywise/widgets/loan_limit_banner.dart';
import 'package:shared_preferences/shared_preferences.dart';

// In memory only: no Firestore, no phone.

MoneyAccount fuliza(int slot, {double? owed, double? limit}) => MoneyAccount(
  id: 'fuliza-sim${slot + 1}',
  name: 'Fuliza (SIM ${slot + 1})',
  kind: AccountKind.loan,
  provider: AccountProvider.safaricom,
  simSlot: slot,
  parentId: 'mpesa-sim${slot + 1}',
  openingBalance: owed == null ? null : -owed,
  openingDate: owed == null ? null : DateTime(2026, 11, 1),
  creditLimit: limit,
);

AccountBalance bal(MoneyAccount a) => AccountBalance.of(a, const []);

void main() {
  test('available is the limit minus what is owed', () {
    final l = LoanLimit.of(bal(fuliza(0, owed: 300, limit: 1000)))!;
    expect(l.owed, 300);
    expect(l.available, 700);
    expect(l.level, LoanLimitLevel.ok);
  });

  test('80% used is "near", all used is "reached", never below 0', () {
    expect(
      LoanLimit.of(bal(fuliza(0, owed: 800, limit: 1000)))!.level,
      LoanLimitLevel.near,
    );
    final over = LoanLimit.of(bal(fuliza(0, owed: 1200, limit: 1000)))!;
    expect(over.available, 0);
    expect(over.level, LoanLimitLevel.reached);
  });

  test('cents are exact', () {
    final l = LoanLimit.of(bal(fuliza(0, owed: 261.71, limit: 500)))!;
    expect(l.available, 238.29);
  });

  test('no limit, or not a loan: nothing', () {
    expect(LoanLimit.of(bal(fuliza(0, owed: 100))), isNull);
    expect(
      LoanLimit.of(
        bal(
          const MoneyAccount(id: 'cash', name: 'Cash', kind: AccountKind.cash),
        ),
      ),
      isNull,
    );
  });

  test('each SIM keeps its own limit', () {
    final all = LoanLimit.all([
      bal(fuliza(0, owed: 900, limit: 1000)),
      bal(fuliza(1, owed: 100, limit: 2000)),
    ]);
    expect(all.map((l) => l.available), [100, 1900]);
    expect(all.map((l) => l.level), [LoanLimitLevel.near, LoanLimitLevel.ok]);
  });

  testWidgets('banner shows near the limit and dismisses until more is '
      'borrowed', (tester) async {
    SharedPreferences.setMockInitialValues({});
    Widget banner(double owed) => MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: LoanLimitBanner(
          key: ValueKey(owed),
          scope: 'u1',
          balances: [
            bal(fuliza(0, owed: owed, limit: 1000)),
            bal(fuliza(1, owed: 100, limit: 1000)),
          ],
        ),
      ),
    );

    await tester.pumpWidget(banner(850));
    await tester.pumpAndSettle();
    expect(find.text('Loan limit almost used'), findsOneWidget);
    expect(find.textContaining('Fuliza (SIM 1)'), findsOneWidget);
    expect(find.textContaining('Fuliza (SIM 2)'), findsNothing);

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('loanLimitBanner')), findsNothing);

    // Same amount owed after a restart: stays hidden.
    await tester.pumpWidget(banner(850.0001));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('loanLimitBanner')), findsNothing);

    // Borrowed more: back, now at the limit.
    await tester.pumpWidget(banner(1000));
    await tester.pumpAndSettle();
    expect(find.text('Loan limit reached'), findsOneWidget);
  });

  testWidgets('Edit account: a Fuliza limit can be set and cleared', (
    tester,
  ) async {
    MoneyAccount? result;
    Future<void> edit(MoneyAccount a, String limit) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await Navigator.of(context).push<MoneyAccount>(
                  MaterialPageRoute(
                    builder: (_) => AccountEditorScreen(existing: a),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('loanLimitField')), limit);
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
    }

    await edit(fuliza(0, owed: 200), '1500');
    expect(result!.creditLimit, 1500);
    expect(result!.creditLimitUpdatedAt, isNotNull);
    expect(result!.openingBalance, -200);

    await edit(result!, '');
    expect(result!.creditLimit, isNull);
    expect(result!.creditLimitUpdatedAt, isNull);
  });
}
