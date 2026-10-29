import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/accounts/account_balances.dart';
import 'package:pennywise/accounts/account_repository.dart';
import 'package:pennywise/accounts/anchor_log.dart';
import 'package:pennywise/accounts/balance_assessment.dart';
import 'package:pennywise/accounts/money_account.dart';
import 'package:pennywise/data/data_exception.dart';
import 'package:pennywise/models/ledger.dart';
import 'package:pennywise/models/transaction_model.dart';
import 'package:pennywise/screens/accounts_screen.dart';
import 'package:pennywise/screens/balance_review_screen.dart';
import 'package:pennywise/widgets/account_cards.dart';

import 'fake_accounts.dart';
import 'fake_transaction_repository.dart';
import 'test_app.dart';

// Balance anchors and reconciliation, in memory only: no Firestore, no
// phone. Every account's balance = its starting balance (anchor) + its
// transactions from the anchor on; an SMS balance is compared, never
// silently applied.

final t0 = DateTime(2026, 10, 10, 12);
DateTime at(int minutes) => t0.add(Duration(minutes: minutes));

MoneyAccount account(String id, {double? opening, DateTime? since}) {
  final a = MoneyAccount.starterSet().firstWhere((a) => a.id == id);
  return opening == null
      ? a
      : a.copyWith(openingBalance: opening, openingDate: since ?? t0);
}

String balanceSms(double amount) =>
    'X Confirmed. Ksh10.00 paid to Y. New M-PESA balance is '
    'Ksh${amount.toStringAsFixed(2)}. Transaction cost, Ksh0.00.';

TransactionModel tx(
  TransactionType type,
  double amount, {
  required DateTime date,
  String? from,
  String? to,
  double? fee,
  int? sim,
  String? sms,
  Account? account,
  Account? toAccount,
  String id = '',
}) =>
    TransactionModel(
      id: id,
      description: 'x',
      amount: amount,
      type: type,
      categoryId: 'food',
      date: date,
      accountId: from,
      toAccountId: to,
      fee: fee,
      simSlot: sim,
      smsText: sms,
      source: sms == null ? TransactionSource.manual : TransactionSource.mpesa,
      account: account ?? (sms == null ? null : Account.mpesa),
      toAccount: toAccount,
    );

AccountBalance bal(MoneyAccount a, List<TransactionModel> txs) =>
    AccountBalance.of(a, txs);

void main() {
  group('anchor and history', () {
    test('manual starting balance, then transactions after it', () {
      final a = account('mpesa-sim1', opening: 1000);
      final b = bal(a, [
        tx(TransactionType.expense, 200, date: at(5), from: 'mpesa-sim1'),
        tx(TransactionType.income, 50, date: at(9), from: 'mpesa-sim1'),
      ]);
      expect(b.shown, 850);
      expect(b.status, BalanceStatus.anchored);
      expect(b.isEstimate, isFalse);
    });

    test('incomplete history before the anchor is ignored; at the anchor '
        'counts', () {
      final a = account('mpesa-sim1', opening: 1000);
      final b = bal(a, [
        tx(TransactionType.expense, 9999, date: at(-60), from: 'mpesa-sim1'),
        tx(TransactionType.expense, 100, date: t0, from: 'mpesa-sim1'),
      ]);
      expect(b.shown, 900);
    });

    test('an old SMS arriving late (before the anchor) changes nothing and '
        'is no evidence', () {
      final a = account('mpesa-sim1', opening: 1000);
      final b = bal(a, [
        tx(TransactionType.expense, 10,
            date: at(-5), from: 'mpesa-sim1', sms: balanceSms(5)),
      ]);
      expect(b.shown, 1000);
      expect(b.reported, isNull);
      expect(b.status, BalanceStatus.anchored);
    });

    test('a user who skipped setup: estimate from history, clearly marked',
        () {
      final b = bal(account('cash'), [
        tx(TransactionType.expense, 80, date: at(1), from: 'cash'),
      ]);
      expect(b.status, BalanceStatus.unverified);
      expect(b.isEstimate, isTrue);
      expect(b.shown, -80);
      final totals = AccountBalance.totals([account('cash')], const [])!;
      expect(totals.unverified, 1);
    });
  });

  group('SMS evidence', () {
    test('agreeing SMS: verified', () {
      final a = account('mpesa-sim1', opening: 1000);
      final b = bal(a, [
        tx(TransactionType.expense, 10,
            date: at(5), from: 'mpesa-sim1', sms: balanceSms(990)),
      ]);
      expect(b.status, BalanceStatus.verified);
      expect(b.shown, 990);
      expect(b.difference, 0);
    });

    test('disagreeing SMS: shown as a difference, never applied', () {
      final a = account('mpesa-sim1', opening: 1000);
      final b = bal(a, [
        tx(TransactionType.expense, 10,
            date: at(5), from: 'mpesa-sim1', sms: balanceSms(700)),
        tx(TransactionType.expense, 40, date: at(9), from: 'mpesa-sim1'),
      ]);
      expect(b.status, BalanceStatus.mismatch);
      expect(b.calculatedAtReport, 990); // at the SMS's own time
      expect(b.difference, -290);
      expect(b.shown, 950); // the user's anchor + history, unchanged
    });

    test('no anchor: latest SMS plus what happened after it', () {
      final b = bal(account('mpesa-sim1'), [
        tx(TransactionType.expense, 10,
            date: at(5), from: 'mpesa-sim1', sms: balanceSms(300)),
        tx(TransactionType.income, 100, date: at(9), from: 'mpesa-sim1'),
      ]);
      expect(b.status, BalanceStatus.fromSms);
      expect(b.shown, 400);
    });

    test('only "balance is" wording counts as balance evidence', () {
      expect(AccountBalance.statedBalance('X Confirmed. Ksh250.00 paid to Y.'),
          isNull);
      expect(
          AccountBalance.statedBalance('Available Fuliza M-PESA limit is Ksh '
              '500.00.'),
          isNull);
      expect(
          AccountBalance.statedBalance('Total Fuliza M-PESA outstanding '
              'amount is Ksh150.50'),
          isNull);
      expect(AccountBalance.statedBalance('Your M-PESA balance is 248.30.'),
          248.3);
    });

    test('SIM 1 and SIM 2 stay apart, also for SMS saved without account '
        'ids; an SMS without a SIM is evidence for neither', () {
      final s1 = account('mpesa-sim1');
      final s2 = account('mpesa-sim2');
      final txs = [
        tx(TransactionType.expense, 10,
            date: at(1), sim: 1, sms: balanceSms(500)), // SIM 2, no ids
        tx(TransactionType.expense, 10,
            date: at(2), sms: balanceSms(42)), // SIM unknown
        tx(TransactionType.expense, 10,
            date: at(3), from: 'mpesa-sim1', sim: 0, sms: balanceSms(100)),
      ];
      expect(bal(s1, txs).reported, 100);
      expect(bal(s2, txs).reported, 500);
      expect(bal(s2, txs).shown, 500);
    });

    test('re-anchoring on an SMS (just after it) counts nothing twice', () {
      final sms = tx(TransactionType.expense, 10,
          date: at(5), from: 'mpesa-sim1', sms: balanceSms(700));
      final later = tx(TransactionType.expense, 40,
          date: at(9), from: 'mpesa-sim1');
      final reAnchored = account('mpesa-sim1',
          opening: 700, since: at(5).add(const Duration(milliseconds: 1)));
      final b = bal(reAnchored, [sms, later]);
      expect(b.shown, 660); // 700 - 40; the SMS's own 10 not again
      expect(b.status, BalanceStatus.anchored);
    });
  });

  group('account types and conventions', () {
    test('own transfer SIM 1 -> SIM 2 moves both; fee once; no income or '
        'spending but the fee', () {
      final txs = [
        tx(TransactionType.transfer, 300,
            date: at(1), from: 'mpesa-sim1', to: 'mpesa-sim2', fee: 7,
            account: Account.mpesa),
      ];
      expect(bal(account('mpesa-sim1', opening: 1000), txs).shown, 693);
      expect(bal(account('mpesa-sim2', opening: 0), txs).shown, 300);
      expect(Ledger.of(txs).spending, 7);
      expect(Ledger.of(txs).income, 0);
    });

    test('Ziidi: savings move, not income or spending', () {
      final txs = [
        tx(TransactionType.savingsContribution, 50,
            date: at(1), from: 'mpesa-sim1', to: 'ziidi-sim1',
            account: Account.mpesa),
      ];
      expect(bal(account('ziidi-sim1', opening: 0), txs).shown, 50);
      expect(bal(account('mpesa-sim1', opening: 100), txs).shown, 50);
      expect(Ledger.of(txs).spending, 0);
      expect(Ledger.of(txs).income, 0);
    });

    test('Fuliza: debt is shown positive while owed', () {
      final fuliza = account('fuliza-sim1', opening: -100); // 100 owed
      final txs = [
        tx(TransactionType.transfer, 50,
            date: at(1), from: 'fuliza-sim1', to: 'mpesa-sim1', fee: 0.5,
            toAccount: Account.mpesa),
        tx(TransactionType.debtRepayment, 120,
            date: at(9), from: 'mpesa-sim1', to: 'fuliza-sim1',
            account: Account.mpesa),
      ];
      expect(bal(fuliza, txs.take(1).toList()).owed, 150.5);
      expect(bal(fuliza, txs).owed, 30.5);
      expect(Ledger.of(txs).spending, 0.5);
    });
  });

  group('a Fuliza loan already in the newest SMS balance', () {
    // A saved SMS record with its real key ("mpesa_<code>", or
    // "mpesa_<code>_FULIZA" for the loan that funded that payment).
    TransactionModel smsTx(
      String id,
      TransactionType type,
      double amount, {
      required DateTime date,
      String? from,
      String? to,
      double? fee,
      int? sim,
      String? sms,
      Account? account,
      Account? toAccount,
      String? reference,
    }) =>
        TransactionModel(
          id: id,
          description: 'x',
          amount: amount,
          type: type,
          categoryId: 'food',
          date: date,
          accountId: from,
          toAccountId: to,
          fee: fee,
          simSlot: sim,
          smsText: sms,
          source: TransactionSource.mpesa,
          reference: reference ??
              id.replaceFirst('mpesa_', '').replaceFirst('_FULIZA', ''),
          account: account,
          toAccount: toAccount,
        );

    // The reported case: a 90.00 payment on SIM 2 says "balance 0.00"; the
    // 59.44 Fuliza loan that funded it arrives 9.7 seconds later.
    final payment = smsTx('mpesa_UJR0000001', TransactionType.expense, 90,
        date: at(0), sim: 1, sms: balanceSms(0), account: Account.mpesa);
    final loan = smsTx(
      'mpesa_UJR0000001_FULIZA',
      TransactionType.transfer,
      59.44,
      date: at(0).add(const Duration(milliseconds: 9700)),
      from: 'fuliza-sim2',
      to: 'mpesa-sim2',
      fee: 0.6,
      sim: 1,
      toAccount: Account.mpesa,
    );

    test('the loan that funded the payment is not added on top of its '
        'stated balance', () {
      final b = bal(account('mpesa-sim2'), [payment, loan]);
      expect(b.status, BalanceStatus.fromSms);
      expect(b.reported, 0);
      expect(b.afterReport, 0);
      expect(b.shown, 0); // was 59.44 before the fix
    });

    test('with a starting balance, the SMS agrees (no false mismatch)', () {
      // 30.56 held, then 90 paid with 59.44 borrowed: 0.00, as the SMS says.
      final wallet = account('mpesa-sim2', opening: 30.56, since: at(-60));
      final b = bal(wallet, [payment, loan]);
      expect(b.calculatedAtReport, 0);
      expect(b.status, BalanceStatus.verified);
      expect(b.shown, 0);
    });

    test('the loan still counts in full on the Fuliza card and its fee as '
        'spending', () {
      final fuliza = account('fuliza-sim2', opening: -100, since: at(-60));
      expect(bal(fuliza, [payment, loan]).owed, 160.04);
      expect(Ledger.of([payment, loan]).spending, 90.6);
    });

    test('a loan for a later payment, after the newest SMS, still counts', () {
      final got = smsTx('mpesa_UJR0000002', TransactionType.income, 500,
          date: at(10), sim: 1, sms: balanceSms(500), account: Account.mpesa);
      // Its own payment's SMS (code 3) isn't saved, so nothing states the
      // balance after this loan: it is added.
      final later = smsTx('mpesa_UJR0000003_FULIZA', TransactionType.transfer,
          20,
          date: at(20),
          from: 'fuliza-sim2',
          to: 'mpesa-sim2',
          fee: 0.2,
          sim: 1,
          toAccount: Account.mpesa);
      final b = bal(account('mpesa-sim2'), [payment, loan, got, later]);
      expect(b.reported, 500);
      expect(b.afterReport, 20);
      expect(b.shown, 520);
    });

    test('a repayment after the newest SMS still counts', () {
      final repay = smsTx('mpesa_UJR0000001', TransactionType.debtRepayment,
          30,
          date: at(5),
          from: 'mpesa-sim2',
          to: 'fuliza-sim2',
          sim: 1,
          account: Account.mpesa);
      final got = smsTx('mpesa_UJR0000004', TransactionType.income, 500,
          date: at(1), sim: 1, sms: balanceSms(500), account: Account.mpesa);
      final b = bal(account('mpesa-sim2'), [got, repay]);
      expect(b.reported, 500);
      expect(b.shown, 470);
    });

    test('only the loan with that payment\'s own key: another record with '
        'the same code is still added after the SMS', () {
      final other = smsTx('mpesa_UJR0000001_COPY', TransactionType.transfer,
          59.44,
          date: at(1),
          from: 'fuliza-sim2',
          to: 'mpesa-sim2',
          sim: 1,
          toAccount: Account.mpesa,
          reference: 'UJR0000001'); // same code, not the loan's own key
      final b = bal(account('mpesa-sim2'), [payment, other]);
      expect(b.shown, 59.44);
    });

    test('another SIM\'s balance SMS changes nothing here', () {
      final sim1Sms = smsTx('mpesa_UJR0000005', TransactionType.expense, 10,
          date: at(30), sim: 0, sms: balanceSms(100), account: Account.mpesa);
      final b2 = bal(account('mpesa-sim2'), [payment, loan, sim1Sms]);
      expect(b2.reported, 0);
      expect(b2.shown, 0);
      final b1 = bal(account('mpesa-sim1'), [payment, loan, sim1Sms]);
      expect(b1.reported, 100);
      expect(b1.shown, 100);
    });
  });

  group('assessment (read-only)', () {
    test('finds what makes balances unreliable, for any user', () {
      final accounts = [
        account('mpesa-sim1'),
        account('mpesa-sim2', opening: 1000),
        account('fuliza-sim1', opening: 50), // positive: credit
      ];
      final txs = [
        tx(TransactionType.expense, 10, date: at(1), sms: balanceSms(5)),
        tx(TransactionType.expense, 100,
            date: at(2),
            from: 'mpesa-sim1',
            sms: 'X Confirmed. Ksh100.00 sent to ZIIDI on 1/10/26. New M-PESA '
                'balance is Ksh400.00.'),
        tx(TransactionType.expense, 10,
            date: at(3), from: 'mpesa-sim2', sms: balanceSms(500)),
        tx(TransactionType.expense, 250, date: at(4), account: Account.mpesa),
        tx(TransactionType.expense, 250,
            date: at(4), sms: balanceSms(250), id: 'mpesa_D'),
      ];
      final titles =
          BalanceAssessment.of(accounts, txs).map((f) => f.title).toList();
      expect(titles, contains('No starting balance'));
      expect(titles, contains('Messages without a SIM'));
      expect(titles, contains('Savings counted as spending or income'));
      expect(titles, contains('Possible duplicates'));
      expect(titles, contains('Fuliza (SIM 1): shows credit'));
      expect(titles, contains('SIM 2 M-Pesa: differs from SMS'));
      expect(titles, contains('SIM 1 M-Pesa: history starts part-way'));
    });

    test('a clean setup has no findings', () {
      final accounts = [account('mpesa-sim1', opening: 1000)];
      final txs = [
        tx(TransactionType.expense, 10,
            date: at(1), from: 'mpesa-sim1', sms: balanceSms(990)),
      ];
      expect(BalanceAssessment.of(accounts, txs), isEmpty);
    });
  });

  group('anchor history (balanceAnchors) and Undo', () {
    Future<(AccountStore, FakeAccountRepository, AnchorKeeper)> keeper() async {
      final repo = FakeAccountRepository([
        account('mpesa-sim1', opening: 1000),
        account('cash'),
      ]);
      final store = AccountStore(repo);
      await Future<void>.delayed(Duration.zero);
      return (store, repo, AnchorKeeper(store));
    }

    test('a change is stored with the value it replaced, in the same write '
        'as the account; Undo restores it exactly', () async {
      final (store, repo, k) = await keeper();
      final before = store.byId('mpesa-sim1')!;
      final txs = [
        tx(TransactionType.expense, 100, date: at(10), from: 'mpesa-sim1'),
      ];
      expect(AccountBalance.of(before, txs).shown, 900);

      expect(
          await k.change(
              before.copyWith(openingBalance: 700, openingDate: at(5)),
              reason: 'Used SMS balance'),
          isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(store.byId('mpesa-sim1')!.openingBalance, 700);
      expect(repo.anchors.single.before, 1000);
      expect(repo.anchors.single.after, 700);
      expect(repo.anchors.single.afterDate, at(5));
      expect(repo.writes, 1); // one atomic write
      expect(AccountBalance.of(store.byId('mpesa-sim1')!, txs).shown, 600);

      expect(await k.undo('mpesa-sim1'), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(store.byId('mpesa-sim1')!.openingBalance, 1000);
      expect(store.byId('mpesa-sim1')!.openingDate, before.openingDate);
      expect(repo.anchors.single.undone, isTrue); // kept, marked
      expect(AccountBalance.of(store.byId('mpesa-sim1')!, txs).shown, 900);
      expect(await k.undo('mpesa-sim1'), isFalse); // nothing left to undo
      expect(repo.writes, 2);
    });

    test('history survives a "reinstall": a new store and keeper read it '
        'back from the repository', () async {
      final (store, repo, k) = await keeper();
      await k.change(
          store.byId('mpesa-sim1')!
              .copyWith(openingBalance: 700, openingDate: at(5)),
          reason: 'Used SMS balance');
      store.dispose();
      final fresh = AccountStore(repo);
      await Future<void>.delayed(Duration.zero);
      final k2 = AnchorKeeper(fresh);
      expect((await k2.history('mpesa-sim1')).single.reason,
          'Used SMS balance');
      expect(await k2.undo('mpesa-sim1'), isTrue);
    });

    test('a failed save reports the failure and changes nothing', () async {
      final (store, repo, k) = await keeper();
      repo.failNextWrite = true;
      await expectLater(
          k.change(
              store.byId('mpesa-sim1')!
                  .copyWith(openingBalance: 700, openingDate: at(5)),
              reason: 'Edited'),
          throwsA(isA<DataException>()));
      expect(store.byId('mpesa-sim1')!.openingBalance, 1000);
      expect(repo.anchors, isEmpty);
    });

    test('a retry of a saved change records nothing twice; a retried Undo '
        'does nothing twice', () async {
      final (store, repo, k) = await keeper();
      final updated = store.byId('mpesa-sim1')!
          .copyWith(openingBalance: 700, openingDate: at(5));
      expect(await k.change(updated, reason: 'Edited'), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(await k.change(updated, reason: 'Edited'), isFalse); // retry
      expect(repo.anchors, hasLength(1));

      // An Undo that failed once, then is retried, then repeated.
      repo.failNextWrite = true;
      await expectLater(k.undo('mpesa-sim1'), throwsA(isA<DataException>()));
      expect(store.byId('mpesa-sim1')!.openingBalance, 700);
      expect(await k.undo('mpesa-sim1'), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(await k.undo('mpesa-sim1'), isFalse);
      expect(repo.anchors.single.undone, isTrue);
      expect(store.byId('mpesa-sim1')!.openingBalance, 1000);
    });

    test('Undo never reverts a later change it did not make', () async {
      final (store, _, k) = await keeper();
      await k.change(
          store.byId('mpesa-sim1')!
              .copyWith(openingBalance: 700, openingDate: at(5)),
          reason: 'Used SMS balance');
      await Future<void>.delayed(Duration.zero);
      // Changed again elsewhere, without the keeper.
      await store.save(store.byId('mpesa-sim1')!
          .copyWith(openingBalance: 650, openingDate: at(8)));
      await Future<void>.delayed(Duration.zero);
      expect(await k.undo('mpesa-sim1'), isFalse);
      expect(store.byId('mpesa-sim1')!.openingBalance, 650);
      // Other accounts untouched.
      expect(store.byId('cash')!.openingBalance, isNull);
    });

    test('an SMS mismatch never changes the starting balance by itself',
        () async {
      final (store, repo, _) = await keeper();
      final b = AccountBalance.of(store.byId('mpesa-sim1')!, [
        tx(TransactionType.expense, 10,
            date: at(5), from: 'mpesa-sim1', sms: balanceSms(5)),
      ]);
      expect(b.status, BalanceStatus.mismatch);
      expect(store.byId('mpesa-sim1')!.openingBalance, 1000);
      expect(repo.anchors, isEmpty);
    });
  });

  group('screens', () {
    void phone(WidgetTester tester) {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.8125;
      addTearDown(tester.view.reset);
    }

    testWidgets('setup offers the latest SMS balance, anchored just after '
        'that message', (tester) async {
      phone(tester);
      final sms = tx(TransactionType.expense, 10,
          date: at(5), from: 'mpesa-sim1', sim: 0, sms: balanceSms(321.5));
      List<MoneyAccount>? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => StartOverScreen(
                  accounts: [account('mpesa-sim1'), account('fuliza-sim1')],
                  transactions: [sms],
                  title: 'Set starting balances',
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Set starting balances'), findsOneWidget);
      await tester.tap(find.textContaining('Use SMS balance'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start over from now'));
      await tester.pumpAndSettle();
      final saved = result!.single; // Fuliza skipped: left unverified
      expect(saved.openingBalance, 321.5);
      expect(saved.openingDate, at(5).add(const Duration(milliseconds: 1)));
    });

    testWidgets('editing only the amount re-anchors at "now", so earlier '
        'transactions are not added on top (12.90 stays 12.90)',
        (tester) async {
      phone(tester);
      final old = DateTime.now().subtract(const Duration(days: 3));
      final repo = FakeAccountRepository([
        for (final a in MoneyAccount.starterSet())
          a.copyWith(openingBalance: 0, openingDate: old),
      ]);
      final saves = [
        for (final h in [48, 30])
          tx(TransactionType.savingsContribution, 1,
              date: DateTime.now().subtract(Duration(hours: h)),
              from: 'mpesa-sim1', to: 'ziidi-sim1', account: Account.mpesa),
      ];
      await pumpApp(tester,
          repository: FakeTransactionRepository(saves), accounts: repo);
      await tester.scrollUntilVisible(find.text('Accounts'), 150,
          scrollable: find
              .descendant(
                  of: find.byType(AccountCards),
                  matching: find.byType(Scrollable))
              .first);
      await tester.tap(find.text('Accounts'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ziidi (SIM 1)'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Starting balance (optional)'),
          '12.90');
      await tester.pumpAndSettle();
      expect(find.text('Now (when you save)'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Save'), 150,
          scrollable: find.byType(Scrollable).hitTestable().first);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = repo.accounts['ziidi-sim1']!;
      expect(saved.openingBalance, 12.9);
      expect(saved.openingDate!.isAfter(saves.first.date), isTrue);
      expect(AccountBalance.of(saved, saves).shown, 12.9);
    });

    testWidgets('Home marks an unverified balance as estimated',
        (tester) async {
      phone(tester);
      await pumpApp(tester,
          repository: FakeTransactionRepository(),
          accounts: FakeAccountRepository(MoneyAccount.starterSet()));
      expect(find.text('Estimated'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Set balances'), 150,
          scrollable: find
              .descendant(
                  of: find.byType(AccountCards),
                  matching: find.byType(Scrollable))
              .first);
      expect(find.text('Set balances'), findsOneWidget);
    });

    testWidgets('review shows a difference; using the SMS balance is logged '
        'and can be undone', (tester) async {
      phone(tester);
      final repo =
          FakeAccountRepository([account('mpesa-sim1', opening: 1000)]);
      final store = (await tester.runAsync(() async {
        final s = AccountStore(repo);
        await Future<void>.delayed(Duration.zero);
        return s;
      }))!;
      final txs = [
        tx(TransactionType.expense, 10,
            date: at(5), from: 'mpesa-sim1', sms: balanceSms(700)),
      ];
      await tester.pumpWidget(MaterialApp(
        home: BalanceReviewScreen(
          accountId: 'mpesa-sim1',
          accounts: store,
          transactions: txs,
          keeper: AnchorKeeper(store),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Difference'), findsOneWidget);
      expect(find.text('KSh 990.00'), findsWidgets); // PennyWise at that time

      await tester.scrollUntilVisible(
          find.text('Use the SMS balance as starting point'), 200);
      await tester.tap(find.text('Use the SMS balance as starting point'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use it'));
      await tester.pumpAndSettle();
      expect(store.byId('mpesa-sim1')!.openingBalance, 700);
      expect(repo.anchors.single.reason, 'Used SMS balance');
      await tester.scrollUntilVisible(
          find.text('Undo "Used SMS balance"'), 200);
      expect(find.text('Undo "Used SMS balance"'), findsOneWidget);
      // Nothing was created to make the figures match.
      expect(txs, hasLength(1));

      await tester.scrollUntilVisible(
          find.text('Undo "Used SMS balance"'), 200);
      await tester.tap(find.text('Undo "Used SMS balance"'));
      await tester.pumpAndSettle();
      expect(store.byId('mpesa-sim1')!.openingBalance, 1000);
    });
  });
}
