import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/accounts/account_repository.dart';
import 'package:pennywise/accounts/money_account.dart';
import 'package:pennywise/data/transaction_store.dart';
import 'package:pennywise/models/transaction_model.dart';
import 'package:pennywise/screens/estimated_amounts_screen.dart';
import 'package:pennywise/services/exchange_rates.dart';
import 'package:pennywise/sms/estimated_amount.dart';
import 'package:pennywise/sms/sms_gateway.dart';
import 'package:pennywise/sms/sms_import_service.dart';

import 'fake_accounts.dart';
import 'fake_sms.dart';
import 'fake_transaction_repository.dart';
import 'test_app.dart';

// Card payments in another currency: saved at that day's market rate,
// marked as estimated, and checked by the user from Settings, Needs review
// or the "detected" notice. Rates, names and amounts are made up.

const usdCard =
    'CONFIRMED. USD 20.00, Auth for card 4111..1111 at ANTHROPIC* CLAUDE SUB '
    'on 2026-10-31 10:53:00 Ref:123456789012.For any queries, contact '
    '0763000000. #KulipaNiEquityCard';
final when = DateTime(2026, 10, 31, 10, 53);

class FixedRates implements ExchangeRates {
  FixedRates(this.rate);
  final double? rate;
  final asked = <String>[];

  @override
  Future<double?> toKes(String currency, DateTime day) async {
    asked.add('$currency ${day.year}-${day.month}-${day.day}');
    return rate;
  }
}

TransactionModel estimated(String id, double kes) => TransactionModel(
  id: id,
  description: 'Anthropic Claude Sub',
  amount: kes,
  type: TransactionType.expense,
  categoryId: 'subscriptions',
  date: when,
  note: EstimatedAmount.note('USD', 20, kes / 20, when),
  source: TransactionSource.equity,
  reference: 'CARD$id',
  account: Account.bank,
  accountId: 'equity',
);

void main() {
  group('rates', () {
    test('asks only for the date and currency, most exact source first', () {
      final urls = OnlineExchangeRates.urls(
        'USD',
        DateTime(2026, 9, 30),
        DateTime(2026, 10, 31),
      );
      expect(urls.first.toString(), contains('currency-api@2026-09-30'));
      expect(urls.first.path, endsWith('/currencies/usd.json'));
      expect(urls.map((u) => u.toString()).join(), isNot(contains('latest')));
      final recent = OnlineExchangeRates.urls(
        'USD',
        DateTime(2026, 10, 31),
        DateTime(2026, 10, 31, 11),
      );
      expect(recent.last.toString(), contains('@latest'));
    });

    test('reads the KES rate from a response; nonsense gives none', () {
      expect(
        OnlineExchangeRates.parse(
          'USD',
          '{"date":"2026-10-31","usd":{"eur":0.9,"kes":129.25}}',
        ),
        129.25,
      );
      expect(OnlineExchangeRates.parse('USD', '{"usd":{}}'), isNull);
      expect(OnlineExchangeRates.parse('USD', 'not json'), isNull);
    });
  });

  group('saving', () {
    Future<(SmsImportService, List<TransactionModel>)> service(
      ExchangeRates? rates,
    ) async {
      final acc = AccountStore(
        FakeAccountRepository([
          ...MoneyAccount.starterSet(),
          const MoneyAccount(
            id: 'equity',
            name: 'Equity',
            kind: AccountKind.bank,
            provider: AccountProvider.equity,
          ),
        ]),
      );
      await Future<void>.delayed(Duration.zero);
      final saved = <TransactionModel>[];
      final s = SmsImportService(
        gateway: FakeSmsGateway(permissionGranted: true),
        settings: FakeSmsSettings()..enabled = true,
        save: (t, key) async {
          saved.add(t);
          return true;
        },
        accounts: () => acc,
        rates: rates,
      );
      await s.start();
      return (s, saved);
    }

    test('a USD card payment is saved at that day\'s rate, as an estimate',
        () async {
      final rates = FixedRates(129.25);
      final (s, saved) = await service(rates);
      await s.handle(RawSms(sender: 'Equity Bank', body: usdCard, date: when));
      final t = saved.single;
      expect(t.amount, 2585.0); // 20.00 × 129.25
      expect(EstimatedAmount.isEstimated(t), isTrue);
      expect(EstimatedAmount.foreignAmount(t), 'USD 20.00');
      expect(t.note, contains('129.25 KES per USD'));
      expect(rates.asked, ['USD 2026-10-31']);
    });

    test('offline: held and tried again later, nothing guessed', () async {
      final (s, saved) = await service(FixedRates(null));
      await s.handle(RawSms(sender: 'Equity Bank', body: usdCard, date: when));
      expect(saved, isEmpty);
    });
  });

  group('checking', () {
    Future<FakeTransactionRepository> show(
      WidgetTester tester,
      List<TransactionModel> items,
    ) async {
      final repo = FakeTransactionRepository(items);
      await tester.pumpWidget(
        MaterialApp(
          home: EstimatedAmountsScreen(store: TransactionStore(repo)),
        ),
      );
      await tester.pumpAndSettle();
      return repo;
    }

    testWidgets('keep the estimate: same amount, no longer estimated', (
      tester,
    ) async {
      final repo = await show(tester, [estimated('e1', 2585)]);
      expect(find.text('About KSh 2,585.00'), findsOneWidget);
      await tester.tap(find.byKey(const Key('keep-e1')));
      await tester.pumpAndSettle();
      final t = repo.items.single;
      expect(t.amount, 2585);
      expect(EstimatedAmount.isEstimated(t), isFalse);
      expect(t.note, contains('Market-rate estimate kept'));
      expect(find.text('All amounts checked'), findsOneWidget);
    });

    testWidgets('enter the statement amount: only the amount and note change',
        (tester) async {
      final repo = await show(tester, [estimated('e2', 2585)]);
      await tester.tap(find.byKey(const Key('correct-e2')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('estimated-amount-field')),
        '2690.40',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final t = repo.items.single;
      expect([t.amount, t.categoryId, t.accountId, t.date], [
        2690.40,
        'subscriptions',
        'equity',
        when,
      ]);
      expect(t.note, 'Card payment of USD 20.00. Amount from statement.');
    });

    testWidgets('Settings: the note opens exactly those payments', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      await pumpApp(
        tester,
        repository: FakeTransactionRepository([estimated('e3', 2585)]),
      );
      await tester.tap(find.byTooltip('Settings').first);
      await tester.pumpAndSettle();
      final button = find.text('Check amounts');
      await tester.scrollUntilVisible(
        button,
        300,
        scrollable: find.byType(Scrollable).hitTestable().first,
      );
      expect(
        find.textContaining('1 card payment in another currency was added'),
        findsOneWidget,
      );
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('Estimated amounts'), findsOneWidget);
      expect(find.text('About KSh 2,585.00'), findsOneWidget);
    });
  });
}
