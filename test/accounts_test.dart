import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/accounts/account_balances.dart';
import 'package:pennywise/accounts/account_repository.dart';
import 'package:pennywise/accounts/money_account.dart';
import 'package:pennywise/models/ledger.dart';
import 'package:pennywise/models/transaction_model.dart';
import 'package:pennywise/sms/sms_gateway.dart';
import 'package:pennywise/sms/sms_import_service.dart';
import 'package:pennywise/sms/sms_parser.dart';
import 'package:pennywise/utils/validators.dart';
import 'package:pennywise/widgets/account_cards.dart';

import 'fake_accounts.dart';
import 'fake_sms.dart';
import 'fake_transaction_repository.dart';
import 'test_app.dart';

// In memory only: no Firestore, no phone.

final when = DateTime(2026, 10, 22, 9, 30);

const tillPayment = 'UJMAB1CD31 Confirmed. Ksh250.00 paid to NAIVAS. on '
    '22/10/26 at 9:30 AM.New M-PESA balance is Ksh1,750.00. Transaction '
    'cost, Ksh0.00.';
const toZiidi = 'UJMAB1CD32 Confirmed. Ksh1.00 sent to ZIIDI on 22/10/26 at '
    '9:31 AM New M-PESA balance is Ksh1,749.00. Transaction cost, Ksh0.00.';
const withdrawal = 'UJMAB1CD33 Confirmed.on 22/10/26 at 9:40 AMWithdraw '
    'Ksh1,000.00 from 123456 - MAMA AGENCIES New M-PESA balance is '
    'Ksh720.00. Transaction cost, Ksh29.00.';

Future<AccountStore> starterStore() async {
  final store = AccountStore(
      FakeAccountRepository(MoneyAccount.starterSet()));
  await Future<void>.delayed(Duration.zero);
  return store;
}

TransactionModel imported(String body, {int? slot, AccountResolver? accounts}) =>
    SmsImportService.toTransaction(
      SmsParser.parse(sender: 'MPESA', body: body, date: when)!,
      simSlot: slot,
      accounts: accounts,
    );

void main() {
  test('starter set: SIM 1 and SIM 2 each get M-Pesa, Ziidi and Fuliza', () {
    final set = MoneyAccount.starterSet();
    final ids = set.map((a) => a.id).toList();
    expect(ids, containsAll(['mpesa-sim1', 'ziidi-sim1', 'fuliza-sim1',
        'mpesa-sim2', 'ziidi-sim2', 'fuliza-sim2', 'cash']));
    final fuliza2 = set.firstWhere((a) => a.id == 'fuliza-sim2');
    expect(fuliza2.kind, AccountKind.loan);
    expect(fuliza2.simSlot, 1);
    expect(fuliza2.parentId, 'mpesa-sim2');
    // Never a bank in the starter set: banks are added by the user.
    expect(set.where((a) => a.kind == AccountKind.bank), isEmpty);
  });

  group('SIM resolution', () {
    test('each SIM resolves to its own account, never the other', () async {
      final store = await starterStore();
      expect(store.forSim(0, AccountKind.mobileMoney)?.id, 'mpesa-sim1');
      expect(store.forSim(1, AccountKind.mobileMoney)?.id, 'mpesa-sim2');
      expect(store.forSim(1, AccountKind.savings)?.id, 'ziidi-sim2');
      expect(store.forSim(null, AccountKind.mobileMoney), isNull);
      expect(store.forSim(2, AccountKind.mobileMoney), isNull); // no SIM 3
    });

    test('a hidden SIM account is not used', () async {
      final repo = FakeAccountRepository([
        for (final a in MoneyAccount.starterSet())
          a.id == 'mpesa-sim2' ? a.copyWith(active: false) : a,
      ]);
      final store = AccountStore(repo);
      await Future<void>.delayed(Duration.zero);
      expect(store.forSim(1, AccountKind.mobileMoney), isNull);
      expect(store.forSim(0, AccountKind.mobileMoney)?.id, 'mpesa-sim1');
    });
  });

  group('import puts each SMS on its SIM', () {
    test('expense on SIM 2 goes to SIM 2 M-Pesa', () async {
      final t = imported(tillPayment, slot: 1, accounts: await starterStore());
      expect(t.accountId, 'mpesa-sim2');
      expect(t.simSlot, 1);
      expect(t.account, Account.mpesa); // generic value kept
    });

    test('unknown SIM: no account guessed', () async {
      final t = imported(tillPayment, accounts: await starterStore());
      expect(t.accountId, isNull);
      expect(t.simSlot, isNull);
    });

    test('Ziidi on SIM 1 goes to Ziidi (SIM 1)', () async {
      final t = imported(toZiidi, slot: 0, accounts: await starterStore());
      expect(t.type, TransactionType.savingsContribution);
      expect(t.accountId, 'mpesa-sim1');
      expect(t.toAccountId, 'ziidi-sim1');
    });

    test('cash withdrawal on SIM 2: SIM 2 M-Pesa -> Cash, fee kept', () async {
      final t = imported(withdrawal, slot: 1, accounts: await starterStore());
      expect(t.type, TransactionType.transfer);
      expect(t.accountId, 'mpesa-sim2');
      expect(t.toAccountId, 'cash');
      expect(t.fee, 29);
    });

    test('without accounts set up, nothing changes from before', () {
      final t = imported(tillPayment, slot: 0);
      expect(t.accountId, isNull);
      expect(t.simSlot, 0);
    });

    test('the import service passes the SIM from the message', () async {
      final store = await starterStore();
      final settings = FakeSmsSettings()..enabled = true;
      final saved = <TransactionModel>[];
      final service = SmsImportService(
        gateway: FakeSmsGateway(permissionGranted: true),
        settings: settings,
        save: (t, key) async {
          saved.add(t);
          return true;
        },
        accounts: () => store,
      );
      await service.start();
      await service.handle(
          RawSms(sender: 'MPESA', body: tillPayment, date: when, simSlot: 1));
      expect(saved.single.accountId, 'mpesa-sim2');
    });
  });

  group('per-account balances', () {
    TransactionModel tx(TransactionType type, double amount,
            {String? from, String? to, double? fee, String? sms}) =>
        TransactionModel(
          description: 'x',
          amount: amount,
          type: type,
          categoryId: 'food',
          date: when,
          accountId: from,
          toAccountId: to,
          fee: fee,
          smsText: sms,
        );

    test('SIM 1 and SIM 2 stay separate; a transfer between them is counted '
        'once and is not spending', () {
      final ledger = Ledger.of([
        tx(TransactionType.income, 1000, from: 'mpesa-sim1'),
        tx(TransactionType.expense, 300, from: 'mpesa-sim2'),
        tx(TransactionType.transfer, 200,
            from: 'mpesa-sim1', to: 'mpesa-sim2', fee: 7),
      ]);
      expect(ledger.balanceOfId('mpesa-sim1'), 1000 - 200 - 7);
      expect(ledger.balanceOfId('mpesa-sim2'), -300 + 200);
      expect(ledger.spending, 307); // the expense and the fee, nothing else
      expect(ledger.income, 1000);
    });

    test('savings go to that SIM\'s Ziidi; a Fuliza repayment reduces its '
        'loan', () {
      final ledger = Ledger.of([
        tx(TransactionType.savingsContribution, 50,
            from: 'mpesa-sim2', to: 'ziidi-sim2'),
        tx(TransactionType.debtRepayment, 100,
            from: 'mpesa-sim1', to: 'fuliza-sim1'),
      ]);
      expect(ledger.balanceOfId('ziidi-sim2'), 50);
      expect(ledger.balanceOfId('ziidi-sim1'), 0);
      expect(ledger.balanceOfId('fuliza-sim1'), 100);
      expect(ledger.spending, 0);
    });

    test('card balance: stated SMS balance first, else estimate', () {
      final sim1 = MoneyAccount.starterSet().first;
      final withSms = AccountBalance.of(sim1, [
        tx(TransactionType.expense, 250,
            from: 'mpesa-sim1',
            sms: 'UJ Confirmed. Ksh250.00 paid to X. New M-PESA balance is '
                'Ksh1,750.00.'),
      ]);
      expect(withSms.reported, 1750);
      expect(withSms.shown, 1750);

      final noSms = AccountBalance.of(sim1, [
        tx(TransactionType.expense, 250, from: 'mpesa-sim1'),
      ]);
      expect(noSms.reported, isNull);
      expect(noSms.isEstimate, isTrue);
      expect(noSms.shown, -250);

      final opened = AccountBalance.of(
          sim1.copyWith(openingBalance: 2000, openingDate: DateTime(2026, 10)),
          [
            tx(TransactionType.expense, 250, from: 'mpesa-sim1'),
          ]);
      expect(opened.isEstimate, isFalse);
      expect(opened.shown, 1750);
    });

    test('stated balance: "Your M-PESA balance is" (Fuliza repayment SMS)',
        () {
      expect(AccountBalance.statedBalance('… Your M-PESA balance is 248.30.'),
          248.3);
      expect(AccountBalance.statedBalance('no balance here'), isNull);
    });
  });

  group('Home and the Add form', () {
    void phone(WidgetTester tester) {
      tester.view.physicalSize = const Size(2400, 3000);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
    }

    testWidgets('account cards sit above the overall summary', (tester) async {
      phone(tester);
      await pumpApp(tester,
          accounts: FakeAccountRepository(MoneyAccount.starterSet()));
      final card = tester.getTopLeft(find.text('SIM 1 M-Pesa'));
      final summary = tester.getTopLeft(find.text('Available balance'));
      expect(card.dy, lessThan(summary.dy));
      expect(find.text('SIM 2 M-Pesa'), findsOneWidget);
    });

    testWidgets('with no accounts, "Set up accounts" creates the starter set',
        (tester) async {
      phone(tester);
      final repo = FakeAccountRepository();
      await pumpApp(tester, accounts: repo);
      await tester.tap(find.text('Set up accounts'));
      await tester.pumpAndSettle();
      expect(repo.accounts.keys, contains('mpesa-sim2'));
      expect(find.text('Fuliza (SIM 1)'), findsOneWidget);
    });

    testWidgets('a transfer from SIM 1 to SIM 2 is saved with both account ids',
        (tester) async {
      phone(tester);
      final repo = FakeTransactionRepository();
      await pumpApp(tester,
          repository: repo,
          accounts: FakeAccountRepository(MoneyAccount.starterSet()));
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Transfer'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Amount'), '200');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Description'), 'To my other line');
      await scrollAndTap(tester, 'To account');
      await tester.tap(find.text('SIM 2 M-Pesa').last);
      await tester.pumpAndSettle();
      await scrollAndTap(tester, 'Save transaction');

      final t = repo.items.single;
      expect(t.type, TransactionType.transfer);
      expect(t.accountId, 'mpesa-sim1');
      expect(t.toAccountId, 'mpesa-sim2');
      expect(t.account, Account.mpesa);
      // Both are "M-Pesa" generically, so only the ids carry the direction.
      expect(t.toAccount, isNull);
    });
  });

  group('phone test fixes', () {
    void phone(WidgetTester tester) {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.8125; // 450 dpi, as on the phone
      addTearDown(tester.view.reset);
    }

    test('starting balance may be zero or negative', () {
      expect(Validators.optionalBalance(''), isNull);
      expect(Validators.optionalBalance('0'), isNull);
      expect(Validators.optionalBalance('-250'), isNull);
      expect(Validators.optionalBalance('-250.75'), isNull);
      expect(Validators.optionalBalance('1500'), isNull);
      expect(Validators.optionalBalance('-1.234'),
          'Use at most 2 decimal places');
      expect(Validators.optionalBalance('--5'), 'Enter a valid amount');
      expect(Validators.optionalBalance('-1000000000'), 'Amount is too large');
    });

    testWidgets('a negative starting balance saves', (tester) async {
      phone(tester);
      final repo = FakeAccountRepository(MoneyAccount.starterSet());
      await pumpApp(tester,
          repository: FakeTransactionRepository(), accounts: repo);
      await tester.scrollUntilVisible(find.text('Accounts'), 300,
          scrollable: find
              .descendant(
                  of: find.byType(AccountCards),
                  matching: find.byType(Scrollable))
              .first);
      await tester.tap(find.text('Accounts'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SIM 1 M-Pesa'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Starting balance (optional)'),
          '-250');
      await scrollAndTap(tester, 'Save');
      expect(repo.accounts['mpesa-sim1']!.openingBalance, -250);
    });

    testWidgets('a cash withdrawal opens and saves after Cash was hidden',
        (tester) async {
      phone(tester);
      final txs = FakeTransactionRepository([
        TransactionModel(
          id: 'w1',
          description: 'Cash withdrawal',
          amount: 1000,
          type: TransactionType.transfer,
          categoryId: 'transfer',
          date: DateTime.now(),
          account: Account.mpesa,
          toAccount: Account.cash,
          accountId: 'mpesa-sim1',
          toAccountId: 'cash',
          fee: 29,
        ),
      ]);
      await pumpApp(tester,
          repository: txs,
          accounts: FakeAccountRepository([
            for (final a in MoneyAccount.starterSet())
              a.id == 'cash' ? a.copyWith(active: false) : a,
          ]));
      await scrollAndTap(tester, 'Cash withdrawal');
      expect(find.text('Edit transaction'), findsOneWidget);
      expect(find.text('Cash (hidden)'), findsOneWidget);
      await scrollAndTap(tester, 'Save changes');
      final saved = txs.items.single;
      expect(saved.accountId, 'mpesa-sim1');
      expect(saved.toAccountId, 'cash');
      expect(saved.toAccount, Account.cash);
      expect(saved.fee, 29);
    });

    testWidgets('Fuliza is entered as the amount owed', (tester) async {
      phone(tester);
      final repo = FakeAccountRepository(MoneyAccount.starterSet());
      await pumpApp(tester,
          repository: FakeTransactionRepository(), accounts: repo);
      await tester.scrollUntilVisible(find.text('Accounts'), 300,
          scrollable: find
              .descendant(
                  of: find.byType(AccountCards),
                  matching: find.byType(Scrollable))
              .first);
      await tester.tap(find.text('Accounts'));
      await tester.pumpAndSettle();
      await scrollAndTap(tester, 'Fuliza (SIM 1)');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Amount owed (optional)'),
          '261.71');
      await scrollAndTap(tester, 'Save');
      expect(repo.accounts['fuliza-sim1']!.openingBalance, -261.71);
      expect(find.textContaining('Owed KSh 261.71'), findsOneWidget);
    });

    test('fresh start: Home totals come from the cards, history ignored', () {
      final start = DateTime(2026, 10, 23, 12);
      final accounts = [
        for (final a in MoneyAccount.starterSet())
          a.copyWith(
            openingBalance: switch (a.id) {
              'mpesa-sim1' => 1500,
              'ziidi-sim1' => 50,
              'fuliza-sim1' => -100,
              _ => 0,
            },
            openingDate: start,
          ),
      ];
      TransactionModel tx(DateTime d, double amount, {String? sms}) =>
          TransactionModel(
            description: 'x',
            amount: amount,
            type: TransactionType.expense,
            categoryId: 'food',
            date: d,
            accountId: 'mpesa-sim1',
            smsText: sms,
          );
      final txs = [
        tx(start.add(const Duration(hours: 1)), 200), // counts
        // Before the fresh start: neither the amount nor its stated SMS
        // balance counts any more.
        tx(start.subtract(const Duration(days: 3)), 9000,
            sms: 'X Confirmed. Ksh9,000.00 paid to Y. New M-PESA balance is '
                'Ksh5.00.'),
      ];
      final totals = AccountBalance.totals(accounts, txs)!;
      expect(totals.available, 1500 - 200); // SIM 1, SIM 2 and Cash
      expect(totals.savings, 50); // loans aren't part of either
      // Until every account has a starting balance, Home keeps using the
      // whole history.
      expect(AccountBalance.totals(MoneyAccount.starterSet(), txs), isNull);
    });

    testWidgets('Start over sets every balance from now', (tester) async {
      phone(tester);
      final repo = FakeAccountRepository(MoneyAccount.starterSet());
      await pumpApp(tester,
          repository: FakeTransactionRepository([
            TransactionModel(
              id: 'old',
              description: 'Old income',
              amount: 5000,
              type: TransactionType.income,
              categoryId: 'salary',
              date: DateTime.now().subtract(const Duration(days: 40)),
              account: Account.mpesa,
            ),
          ]),
          accounts: repo);
      await tester.scrollUntilVisible(find.text('Accounts'), 300,
          scrollable: find
              .descendant(
                  of: find.byType(AccountCards),
                  matching: find.byType(Scrollable))
              .first);
      await tester.tap(find.text('Accounts'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start over'));
      await tester.pumpAndSettle();
      for (final (label, value) in [
        ('SIM 1 M-Pesa', '1500'),
        ('SIM 2 M-Pesa', '200'),
        ('Ziidi (SIM 1)', '50'),
        ('Ziidi (SIM 2)', '0'),
        ('Fuliza (SIM 1): amount owed', '100'),
        ('Fuliza (SIM 2): amount owed', '0'),
        ('Cash', '300'),
      ]) {
        final field = find.widgetWithText(TextFormField, label);
        await tester.scrollUntilVisible(field, 200,
            scrollable: find.byType(Scrollable).hitTestable().first);
        await tester.enterText(field, value);
      }
      await scrollAndTap(tester, 'Start over from now');
      expect(repo.accounts['fuliza-sim1']!.openingBalance, -100);
      expect(repo.accounts['mpesa-sim1']!.openingDate, isNotNull);

      await tester.pageBack();
      await tester.pumpAndSettle();
      // 1,500 + 200 + 300; the 5,000 from last month no longer counts.
      expect(find.text('KSh 2,000.00'), findsOneWidget);
      expect(find.text('Savings KSh 50.00'), findsOneWidget);
    });

    for (final scale in [1.0, 1.3]) {
      testWidgets('"SIM not recorded" card fits (text size x$scale)',
          (tester) async {
        phone(tester);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await pumpApp(tester,
            repository: FakeTransactionRepository([
              for (var i = 0; i < 622; i++)
                TransactionModel(
                  id: 'old$i',
                  description: 'Old $i',
                  amount: 10,
                  type: TransactionType.expense,
                  categoryId: 'food',
                  date: when,
                  account: Account.mpesa,
                ),
            ]),
            accounts: FakeAccountRepository(MoneyAccount.starterSet()));
        // An overflow would have failed the test while building.
        await tester.scrollUntilVisible(find.text('SIM not recorded'), 300,
            scrollable: find
                .descendant(
                    of: find.byType(AccountCards),
                    matching: find.byType(Scrollable))
                .first);
        expect(find.text('622'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('editing keeps toAccountId only where there is another side', () {
    void phone(WidgetTester tester) {
      tester.view.physicalSize = const Size(2400, 3000);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
    }

    TransactionModel existing(TransactionType type,
            {required String category, String? toAccountId}) =>
        TransactionModel(
          id: 'e1',
          description: 'Old entry',
          amount: 200,
          type: type,
          categoryId: category,
          date: DateTime.now(),
          account: Account.mpesa,
          accountId: 'mpesa-sim1',
          toAccountId: toAccountId,
        );

    /// Opens [t] in the Edit form, applies [change] and saves it.
    Future<TransactionModel> edit(WidgetTester tester, TransactionModel t,
        [Future<void> Function()? change]) async {
      phone(tester);
      final repo = FakeTransactionRepository([t]);
      await pumpApp(tester,
          repository: repo,
          accounts: FakeAccountRepository(MoneyAccount.starterSet()));
      await scrollAndTap(tester, 'Old entry');
      expect(find.text('Edit transaction'), findsOneWidget);
      await change?.call();
      await scrollAndTap(tester, 'Save changes');
      return repo.items.single;
    }

    final sim1ToSim2 = existing(TransactionType.transfer,
        category: 'transfer', toAccountId: 'mpesa-sim2');

    for (final (label, type, category) in [
      ('Expense', TransactionType.expense, 'Food'),
      ('Income', TransactionType.income, 'Salary'),
      ('Refund', TransactionType.refund, 'Food'),
    ]) {
      testWidgets('SIM 1 -> SIM 2 transfer changed to $label drops '
          'toAccountId', (tester) async {
        final saved = await edit(tester, sim1ToSim2, () async {
          await scrollAndTap(tester, label);
          await scrollAndTap(tester, category);
        });
        expect(saved.type, type);
        expect(saved.toAccountId, isNull); // the rules reject it here
        expect(saved.toAccount, isNull);
        expect(saved.accountId, 'mpesa-sim1');
      });
    }

    testWidgets('a transfer edited as a transfer keeps both ids',
        (tester) async {
      final saved = await edit(tester, sim1ToSim2);
      expect(saved.type, TransactionType.transfer);
      expect(saved.accountId, 'mpesa-sim1');
      expect(saved.toAccountId, 'mpesa-sim2');
    });

    testWidgets('a Fuliza repayment keeps its loan account', (tester) async {
      final saved = await edit(
          tester,
          existing(TransactionType.debtRepayment,
              category: 'debt_repayment', toAccountId: 'fuliza-sim1'));
      expect(saved.type, TransactionType.debtRepayment);
      expect(saved.toAccountId, 'fuliza-sim1');
    });

    testWidgets('a Ziidi save keeps that SIM\'s Ziidi', (tester) async {
      final saved = await edit(
          tester,
          existing(TransactionType.savingsContribution,
              category: 'savings', toAccountId: 'ziidi-sim1'));
      expect(saved.type, TransactionType.savingsContribution);
      expect(saved.toAccountId, 'ziidi-sim1');
    });

    testWidgets('an expense changed to a debt repayment gets no other side',
        (tester) async {
      final saved = await edit(
          tester, existing(TransactionType.expense, category: 'food'),
          () async {
        await scrollAndTap(tester, 'Debt repayment');
      });
      expect(saved.type, TransactionType.debtRepayment);
      expect(saved.toAccountId, isNull);
    });
  });
}
