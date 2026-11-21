import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/accounts/account_balances.dart';
import 'package:pennywise/accounts/account_repository.dart';
import 'package:pennywise/accounts/loan_limit.dart';
import 'package:pennywise/accounts/money_account.dart';
import 'package:pennywise/models/transaction_model.dart';
import 'package:pennywise/sms/sms_import_service.dart';
import 'package:pennywise/sms/sms_parser.dart';

import 'fake_accounts.dart';

// Which SMS balance a card trusts when messages arrive seconds apart, and
// Fuliza cards from the outstanding amount M-Pesa states. In memory only.
// The message texts are real M-Pesa wording; names and numbers are changed.

// SIM 1, 20/11: money received, then M-Pesa used it to clear the Fuliza.
const received = 'UKK8B3A7LZ Confirmed.You have received Ksh300.00 from '
    'JANE  DOE 0712***345 on 20/11/26 at 1:40 PM  New M-PESA balance is '
    'Ksh300.00. Invest & earn daily interest with ZIIDI on https://saf.cx/x';
const repaid = 'UKK3I3M68U\n Confirmed. Ksh 278.26 from your M-PESA has been '
    'used to fully pay your outstanding Fuliza M-PESA. Available Fuliza '
    'M-PESA limit is Ksh 300.00. Your M-PESA balance is 21.74.';

// SIM 1, 19/11: a payment funded by Fuliza.
const offer = 'UKJ3I3J1CY Confirmed. Ksh20.00 sent to Safaricom Offers for '
    'account Tunukiwa on 19/11/26 at 6:37 PM New M-PESA balance is Ksh0.00. '
    'Transaction cost, Ksh0.00.Amount you can transact within the day is '
    '499,960.00.';
const offerLoan = 'UKJ3I3J1CY Confirmed. Fuliza M-PESA amount is Ksh 20.00. '
    'Access Fee charged Ksh 0.20. Total Fuliza M-PESA outstanding amount is '
    'Ksh278.26 due on 17/12/26. To check daily charges, Dial *334#OK Select '
    'Query Charges';

// SIM 2, 20/11: a payment funded by Fuliza.
const sent2 = 'UKKHK3J3HO Confirmed. Ksh150.00 sent to JOHN  DOE on 20/11/26 '
    'at 3:43 PM. New M-PESA balance is Ksh0.00. Transaction cost, Ksh0.00. '
    'Amount you can transact within the day is 499,850.00.';
const loan2 = 'UKKHK3J3HO Confirmed. Fuliza M-PESA amount is Ksh 106.06. '
    'Access Fee charged Ksh 1.07. Total Fuliza M-PESA outstanding amount is '
    'Ksh107.13 due on 20/12/26. To check daily charges, Dial *334#OK Select '
    'Query Charges';

final t1340 = DateTime(2026, 11, 20, 13, 40, 40);

TransactionModel imp(String body, DateTime at, int slot, AccountResolver a) {
  final p = SmsParser.parse(sender: 'MPESA', body: body, date: at)!;
  return SmsImportService.toTransaction(p, simSlot: slot, accounts: a)
      .withId(p.dedupeKey);
}

Future<AccountStore> store(List<MoneyAccount> accounts) async {
  final s = AccountStore(FakeAccountRepository(accounts));
  await Future<void>.delayed(Duration.zero);
  return s;
}

MoneyAccount byId(List<MoneyAccount> all, String id) =>
    all.firstWhere((a) => a.id == id);

void main() {
  group('SIM 1: 300 received, then the Fuliza repaid from it', () {
    final accounts = MoneyAccount.starterSet();

    Future<List<TransactionModel>> history(
        Duration gap, {bool repaymentFirst = false}) async {
      final s = await store(accounts);
      final r = imp(received, t1340, 0, s);
      final p = imp(repaid, t1340.add(gap), 0, s);
      return repaymentFirst ? [p, r] : [r, p];
    }

    for (final gap in [Duration.zero, const Duration(seconds: 3),
        const Duration(seconds: -1)]) {
      for (final repaymentFirst in [false, true]) {
        test('${gap.inSeconds}s apart, '
            '${repaymentFirst ? 'repayment' : 'received'} listed first '
            '-> M-Pesa 21.74, Fuliza 0', () async {
          final txs = await history(gap, repaymentFirst: repaymentFirst);
          final mpesa = AccountBalance.of(byId(accounts, 'mpesa-sim1'), txs);
          expect(mpesa.status, BalanceStatus.fromSms);
          expect(mpesa.reported, 21.74);
          expect(mpesa.afterReport, 0);
          expect(mpesa.shown, 21.74);
          final fuliza = AccountBalance.of(byId(accounts, 'fuliza-sim1'), txs);
          expect(fuliza.shownFromSms, isTrue);
          expect(fuliza.owed, 0);
        });
      }
    }

    test('a later movement still counts after the SMS', () async {
      final s = await store(accounts);
      final txs = [
        imp(received, t1340, 0, s),
        imp(repaid, t1340, 0, s),
        TransactionModel(
          id: 'm1',
          description: 'Lunch',
          amount: 1.74,
          type: TransactionType.expense,
          categoryId: 'food',
          date: t1340.add(const Duration(hours: 1)),
          accountId: 'mpesa-sim1',
        ),
      ];
      final mpesa = AccountBalance.of(byId(accounts, 'mpesa-sim1'), txs);
      expect(mpesa.shown, 20.00);
    });

    test('unrelated same-second balances: the newest by time, as before',
        () async {
      final s = await store(accounts);
      final a = imp(received, t1340, 0, s);
      // Neither balance follows from the other: nothing to reorder.
      final b = imp(
          'UJMAB1CD31 Confirmed. Ksh250.00 paid to NAIVAS. on 20/11/26 at '
          '1:40 PM.New M-PESA balance is Ksh1,750.00. Transaction cost, '
          'Ksh0.00.',
          t1340.add(const Duration(seconds: 1)),
          0,
          s);
      final mpesa = AccountBalance.latestSmsBalance(
          byId(accounts, 'mpesa-sim1'), [b, a]);
      expect(mpesa!.amount, 1750.00);
    });
  });

  group('Fuliza cards from the outstanding amount M-Pesa states', () {
    test('statedOutstanding reads only the outstanding wording', () {
      expect(AccountBalance.statedOutstanding(offerLoan), 278.26);
      expect(AccountBalance.statedOutstanding(repaid), 0);
      expect(
          AccountBalance.statedOutstanding('XX12345678 Confirmed. Ksh 50.00 '
              'from your M-PESA has been used to partially pay your '
              'outstanding Fuliza M-PESA. Available Fuliza M-PESA limit is '
              'Ksh 300.00.'),
          isNull);
      expect(AccountBalance.statedOutstanding(received), isNull);
      expect(AccountBalance.statedOutstanding(null), isNull);
    });

    test('SIM 1: history 3.00 off, the full repayment says 0 -> owed 0',
        () async {
      final accounts = <MoneyAccount>[
        for (final a in MoneyAccount.starterSet())
          a.id == 'fuliza-sim1'
              ? MoneyAccount(
                  id: a.id,
                  name: a.name,
                  kind: a.kind,
                  provider: a.provider,
                  simSlot: a.simSlot,
                  parentId: a.parentId,
                  openingBalance: -261.06,
                  openingDate: DateTime(2026, 11, 1),
                  creditLimit: 300,
                )
              : a,
      ];
      final s = await store(accounts);
      final at = DateTime(2026, 11, 19, 18, 37, 11);
      final txs = [
        imp(offer, at, 0, s),
        imp(offerLoan, at.add(const Duration(seconds: 1)), 0, s),
        imp(received, t1340, 0, s),
        imp(repaid, t1340, 0, s),
      ];
      final fuliza = AccountBalance.of(byId(accounts, 'fuliza-sim1'), txs);
      expect(fuliza.computed, -3.00); // the history alone
      expect(fuliza.owed, 0);
      expect(fuliza.shownFromSms, isTrue);
      expect(fuliza.differs, isTrue); // the gap is still pointed out
      final limit = LoanLimit.of(fuliza)!;
      expect(limit.available, 300);
      expect(AccountBalance.of(byId(accounts, 'mpesa-sim1'), txs).shown,
          21.74);
    });

    test('SIM 2: history 10.15 too high, the loan SMS says 107.13', () async {
      final accounts = [
        for (final a in MoneyAccount.starterSet())
          a.id == 'fuliza-sim2'
              ? a.copyWith(
                  openingBalance: -10.15, openingDate: DateTime(2026, 11, 1))
              : a,
      ];
      final s = await store(accounts);
      final at = DateTime(2026, 11, 20, 15, 43, 11);
      final txs = [
        imp(sent2, at, 1, s),
        imp(loan2, at.add(const Duration(seconds: 3)), 1, s),
      ];
      final fuliza = AccountBalance.of(byId(accounts, 'fuliza-sim2'), txs);
      expect(fuliza.computed, -117.28);
      expect(fuliza.owed, 107.13);
      expect(fuliza.difference, 10.15);
      expect(AccountBalance.of(byId(accounts, 'mpesa-sim2'), txs).shown, 0);
    });

    test('a loan with no outstanding SMS keeps its history figure', () async {
      final accounts = MoneyAccount.starterSet();
      final txs = [
        TransactionModel(
          id: 'manual',
          description: 'Fuliza',
          amount: 50,
          type: TransactionType.transfer,
          categoryId: 'transfer',
          date: t1340,
          accountId: 'fuliza-sim1',
          toAccountId: 'mpesa-sim1',
        ),
      ];
      final fuliza = AccountBalance.of(byId(accounts, 'fuliza-sim1'), txs);
      expect(fuliza.shownFromSms, isFalse);
      expect(fuliza.owed, 50);
    });
  });
}
