import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/accounts/account_balances.dart';
import 'package:pennywise/accounts/account_repository.dart';
import 'package:pennywise/accounts/money_account.dart';
import 'package:pennywise/data/data_exception.dart';
import 'package:pennywise/data/transaction_store.dart';
import 'package:pennywise/models/ledger.dart';
import 'package:pennywise/models/transaction_model.dart';
import 'package:pennywise/screens/fuliza_import_screen.dart';
import 'package:pennywise/sms/fuliza_import.dart';
import 'package:pennywise/sms/sms_gateway.dart';
import 'package:pennywise/sms/sms_import_service.dart';
import 'package:pennywise/sms/sms_parser.dart';

import 'fake_accounts.dart';
import 'fake_sms.dart';
import 'fake_transaction_repository.dart';

// Fuliza import, in memory only: a fake inbox, fake settings and a fake
// repository. No Firestore (real or emulator), no phone. Message shapes are
// copied from real Fuliza messages; codes and amounts are made up.

final day = DateTime(2026, 10, 1, 9);

String draw(String code, String amount, String fee) =>
    '$code Confirmed. Fuliza M-PESA amount is Ksh $amount. Access Fee '
    'charged Ksh $fee. Total Fuliza M-PESA outstanding amount is Ksh999.00 '
    'due on 21/11/26. To check daily charges, Dial *234*0#OK Select Query '
    'Charges';
String repay(String code, String amount) =>
    '$code\n Confirmed. Ksh $amount from your M-PESA has been used to fully '
    'pay your outstanding Fuliza M-PESA. Available Fuliza M-PESA limit is Ksh '
    '500.00. Your M-PESA balance is 248.30.';
String payment(String code, String amount) =>
    '$code Confirmed. Ksh$amount paid to MAMA PIMA. on 1/10/26 at 9:00 AM.New '
    'M-PESA balance is Ksh0.00. Transaction cost, Ksh0.00.';
const failed = 'Failed. Insufficient funds in your M-PESA account as well as '
    'Fuliza M-PESA to send KSH90.00. Your M-PESA balance KSH2.00.';

RawSms sms(String body, {int? slot, int minutes = 0}) => RawSms(
    sender: 'MPESA',
    body: body,
    date: day.add(Duration(minutes: minutes)),
    simSlot: slot);

Future<AccountStore> starterAccounts() async {
  final store = AccountStore(FakeAccountRepository(MoneyAccount.starterSet()));
  await Future<void>.delayed(Duration.zero);
  return store;
}

TransactionModel convert(String body, int? slot, AccountResolver? accounts) =>
    SmsImportService.toTransaction(
      SmsParser.parse(sender: 'MPESA', body: body, date: day)!,
      simSlot: slot,
      accounts: accounts,
    );

/// A repository that records every write, and can fail on one key.
class RecordingRepository extends FakeTransactionRepository {
  RecordingRepository([super.initial]);

  final writes = <String>[];
  final deletes = <String>[];
  String? failOn;

  @override
  Future<bool> addDetected(TransactionModel t,
      {required String dedupeKey}) async {
    if (dedupeKey == failOn) throw const DataException('No connection.');
    writes.add(dedupeKey);
    return super.addDetected(t, dedupeKey: dedupeKey);
  }

  @override
  Future<void> delete(String id) async {
    deletes.add(id);
    return super.delete(id);
  }
}

class Setup {
  Setup(this.gateway, this.settings, this.repo, this.store, this.importer);
  final FakeSmsGateway gateway;
  final FakeSmsSettings settings;
  final RecordingRepository repo;
  final TransactionStore store;
  final FulizaImporter importer;
}

Future<Setup> setup(List<RawSms> inbox,
    {List<TransactionModel> existing = const [],
    bool withAccounts = true,
    FakeSmsSettings? settings}) async {
  final gateway = FakeSmsGateway(permissionGranted: true)..inbox.addAll(inbox);
  final s = settings ?? FakeSmsSettings(enabled: true);
  final repo = RecordingRepository(existing);
  final store = TransactionStore(repo);
  final accounts = withAccounts ? await starterAccounts() : null;
  await Future<void>.delayed(Duration.zero);
  final importer = FulizaImporter(
    gateway: gateway,
    settings: s,
    accounts: () => accounts,
    existingIds: () => {for (final t in store.transactions) t.id},
    save: (t, key) => store.addDetected(t, dedupeKey: key),
    delete: store.delete,
  );
  return Setup(gateway, s, repo, store, importer);
}

void main() {
  group('conversion', () {
    late AccountStore accounts;
    setUp(() async => accounts = await starterAccounts());

    for (final (slot, sim) in [(0, 'sim1'), (1, 'sim2')]) {
      test('a draw on SIM ${slot + 1}: Fuliza -> M-Pesa of that SIM, with '
          'the access fee', () {
        final t = convert(draw('UJMAB1CDA1', '50.00', '0.50'), slot, accounts);
        expect(t.type, TransactionType.transfer);
        expect(t.accountId, 'fuliza-$sim');
        expect(t.toAccountId, 'mpesa-$sim');
        expect(t.account, isNull); // no generic "from": borrowed money
        expect(t.toAccount, Account.mpesa);
        expect(t.toAccount, isNot(Account.cash)); // never a cash move
        expect(t.fee, 0.5);
        expect(t.amount, 50);
        expect(t.date, day);
        expect(t.reference, 'UJMAB1CDA1');
        expect(t.simSlot, slot);
        expect(t.categoryId, 'transfer');
      });

      test('a repayment on SIM ${slot + 1}: M-Pesa -> Fuliza of that SIM',
          () {
        final t = convert(repay('UJMAB1CDA2', '151.70'), slot, accounts);
        expect(t.type, TransactionType.debtRepayment);
        expect(t.accountId, 'mpesa-$sim');
        expect(t.toAccountId, 'fuliza-$sim');
        expect(t.account, Account.mpesa);
        expect(t.fee, isNull);
        expect(t.interest, isNull);
        expect(t.amount, 151.7);
      });
    }

    test('unknown SIM or no accounts: no account guessed', () {
      final unknown = convert(draw('UJMAB1CDA3', '50.00', '0.50'), null, accounts);
      expect(unknown.accountId, isNull);
      expect(unknown.toAccountId, isNull);
      final none = convert(repay('UJMAB1CDA4', '10.00'), 0, null);
      expect(none.accountId, isNull);
      expect(none.toAccountId, isNull);
    });

    test('the draw keeps its own key; the payment it funded keeps its code',
        () {
      final d = SmsParser.parse(
          sender: 'MPESA', body: draw('UJMAB1CDA5', '50.00', '0.50'), date: day)!;
      final p = SmsParser.parse(
          sender: 'MPESA', body: payment('UJMAB1CDA5', '60.00'), date: day)!;
      expect(d.dedupeKey, 'mpesa_UJMAB1CDA5_FULIZA');
      expect(p.dedupeKey, 'mpesa_UJMAB1CDA5');
    });
  });

  group('balances and spending', () {
    final accounts = [
      for (final a in MoneyAccount.starterSet())
        a.copyWith(openingBalance: 0, openingDate: DateTime(2026, 9, 1)),
    ];
    late AccountStore store;
    setUp(() async => store = await starterAccounts());

    // PennyWise's own figure (the SMS-stated M-Pesa balance aside).
    double card(String id, List<TransactionModel> txs) =>
        AccountBalance.of(accounts.firstWhere((a) => a.id == id), txs)
            .computed;

    test('pay 60 with 10 on M-Pesa, Fuliza lends 50 + 0.50, then repaid',
        () {
      final pay = TransactionModel(
        id: 'mpesa_UJMAB1CDB1',
        description: 'Mama Pima',
        amount: 60,
        type: TransactionType.expense,
        categoryId: 'food',
        date: day,
        source: TransactionSource.mpesa,
        account: Account.mpesa,
        accountId: 'mpesa-sim1',
      );
      final loan = convert(draw('UJMAB1CDB1', '50.00', '0.50'), 0, store);
      final repaid = convert(repay('UJMAB1CDB2', '50.50'), 0, store);

      var txs = [pay, loan];
      expect(card('fuliza-sim1', txs), -50.5); // owed 50.50
      expect(card('mpesa-sim1', txs), -60 + 50);
      var ledger = Ledger.of(txs);
      expect(ledger.spending, 60.5); // the payment + the fee, once
      expect(ledger.income, 0); // borrowing isn't income
      // Generic balance: the loan arrives in M-Pesa and nothing leaves any
      // generic account for it.
      expect(ledger.balanceOf(Account.mpesa), -60 + 50);
      expect(ledger.available, -10);

      txs = [pay, loan, repaid];
      expect(card('fuliza-sim1', txs), 0); // nothing owed
      expect(card('mpesa-sim1', txs), -10 - 50.5);
      ledger = Ledger.of(txs);
      expect(ledger.spending, 60.5); // repaying isn't spending
      expect(ledger.available, -60.5);
      expect(card('fuliza-sim2', txs), 0); // the other SIM is untouched
    });

    test('ordinary transfers, cash moves and other types are unchanged', () {
      final cashMove = TransactionModel(
        description: 'Cash withdrawal',
        amount: 1000,
        type: TransactionType.transfer,
        categoryId: 'transfer',
        date: day,
        account: Account.mpesa,
        toAccount: Account.cash,
        accountId: 'mpesa-sim1',
        toAccountId: 'cash',
        fee: 29,
      );
      final sim1to2 = TransactionModel(
        description: 'To my other line',
        amount: 200,
        type: TransactionType.transfer,
        categoryId: 'transfer',
        date: day,
        account: Account.mpesa,
        accountId: 'mpesa-sim1',
        toAccountId: 'mpesa-sim2',
      );
      final legacy = TransactionModel(
        description: 'Old withdrawal',
        amount: 500,
        type: TransactionType.transfer,
        categoryId: 'transfer',
        date: day,
        account: Account.mpesa,
        toAccount: Account.cash,
      );
      final ledger = Ledger.of([cashMove, sim1to2, legacy]);
      expect(ledger.balanceOf(Account.mpesa), -1000 - 29 - 200 - 500);
      expect(ledger.balanceOf(Account.cash), 1500);
      expect(ledger.spending, 29);
      expect(ledger.available, -29);
      expect(ledger.balanceOfId('mpesa-sim2'), 200);
    });
  });

  group('preview, import and undo', () {
    final inbox = [
      sms(payment('UJMAB1CDC1', '60.00'), slot: 0),
      sms(draw('UJMAB1CDC1', '50.00', '0.50'), slot: 0, minutes: 1),
      sms(repay('UJMAB1CDC2', '50.50'), slot: 0, minutes: 60),
      sms(draw('UJMAB1CDC3', '20.00', '0.20'), slot: 1, minutes: 70),
      sms(draw('UJMAB1CDC3', '20.00', '0.20'), slot: 1, minutes: 70), // repeated
      sms(draw('UJMAB1CDC4', '10.00', '0.10'), minutes: 80), // SIM unknown
      sms(failed, slot: 0, minutes: 90),
    ];

    test('preview reads only: no writes, no handled keys, no id list',
        () async {
      final s = await setup(inbox);
      final p = await s.importer.preview();
      expect(s.repo.writes, isEmpty);
      expect(s.settings.handled, isEmpty);
      expect(s.settings.fulizaIds, isEmpty);

      expect(p.eligible.map((i) => i.key),
          ['mpesa_UJMAB1CDC1_FULIZA', 'mpesa_UJMAB1CDC2', 'mpesa_UJMAB1CDC3_FULIZA']);
      expect(p.count(FulizaStatus.repeated), 1);
      expect(p.count(FulizaStatus.needsReview), 1); // the unknown SIM
      final sim1 = p.bySim[0]!, sim2 = p.bySim[1]!;
      expect((sim1.draws, sim1.borrowed, sim1.fees), (1, 50, 0.5));
      expect((sim1.repayments, sim1.repaid), (1, 50.5));
      expect(sim1.debtChange, 0);
      expect((sim2.draws, sim2.borrowed, sim2.fees), (1, 20, 0.2));
    });

    test('no accounts set up: everything needs review, nothing eligible',
        () async {
      final s = await setup(inbox, withAccounts: false);
      final p = await s.importer.preview();
      expect(p.eligible, isEmpty);
      expect(p.count(FulizaStatus.needsReview), 4);
    });

    test('import creates only missing records, never overwrites, records '
        'exact ids and handled keys', () async {
      final existing = convert(repay('UJMAB1CDC2', '50.50'), 0, null)
          .withId('mpesa_UJMAB1CDC2'); // already saved earlier
      final s = await setup(inbox, existing: [existing]);
      final p = await s.importer.preview();
      expect(p.count(FulizaStatus.alreadyImported), 1);

      final r = await s.importer.importEligible(p);
      expect(r.done, 2);
      expect(r.error, isNull);
      expect(s.repo.writes, ['mpesa_UJMAB1CDC1_FULIZA', 'mpesa_UJMAB1CDC3_FULIZA']);
      expect(s.settings.fulizaIds, ['mpesa_UJMAB1CDC1_FULIZA', 'mpesa_UJMAB1CDC3_FULIZA']);
      expect(s.settings.handled,
          containsAll(['mpesa_UJMAB1CDC1_FULIZA', 'mpesa_UJMAB1CDC3_FULIZA']));
      // The earlier record is untouched (no accounts on it, as saved).
      final kept = s.repo.items.firstWhere((t) => t.id == 'mpesa_UJMAB1CDC2');
      expect(kept.accountId, isNull);
      expect(s.repo.items, hasLength(3));
    });

    test('a record that appears in between is skipped, not overwritten',
        () async {
      final s = await setup(inbox);
      final p = await s.importer.preview();
      // Saved elsewhere after the preview, e.g. on another phone.
      await s.repo.addDetected(
          convert(repay('UJMAB1CDC2', '50.50'), 0, null), dedupeKey: 'mpesa_UJMAB1CDC2');
      s.repo.writes.clear();
      final r = await s.importer.importEligible(p);
      expect((r.done, r.skipped), (2, 1));
      expect(s.settings.fulizaIds, isNot(contains('mpesa_UJMAB1CDC2')));
      expect(
          s.repo.items.firstWhere((t) => t.id == 'mpesa_UJMAB1CDC2').accountId,
          isNull);
    });

    test('a failure part-way stops, keeping an exact list of what was saved',
        () async {
      final s = await setup(inbox);
      s.repo.failOn = 'mpesa_UJMAB1CDC2';
      final r = await s.importer.importEligible(await s.importer.preview());
      expect(r.done, 1);
      expect(r.error, 'No connection.');
      expect(s.settings.fulizaIds, ['mpesa_UJMAB1CDC1_FULIZA']);
      expect(s.settings.handled, {'mpesa_UJMAB1CDC1_FULIZA'}); // not the failed one
    });

    test('repeated taps import once', () async {
      final s = await setup(inbox);
      final p = await s.importer.preview();
      final first = s.importer.importEligible(p);
      final second = await s.importer.importEligible(p); // while running
      expect(second.done, 0);
      expect(second.error, isNotNull);
      await first;
      expect(s.repo.writes, hasLength(3));
      // Running it again later creates nothing new.
      final again = await s.importer.importEligible(p);
      expect(again.done, 0);
      expect(again.skipped, 3);
      expect(s.repo.items, hasLength(3));
    });

    test('Undo deletes exactly the imported ids, keeps handled keys, and '
        'the next scan does not bring them back', () async {
      final manual = TransactionModel(
        id: 'm1',
        description: 'Lunch',
        amount: 50,
        type: TransactionType.expense,
        categoryId: 'food',
        date: day,
      );
      final s = await setup(inbox, existing: [manual]);
      await s.importer.importEligible(await s.importer.preview());
      expect(s.repo.items, hasLength(4));

      final r = await s.importer.undo();
      expect(r.done, 3);
      expect(s.repo.deletes, ['mpesa_UJMAB1CDC1_FULIZA', 'mpesa_UJMAB1CDC2',
          'mpesa_UJMAB1CDC3_FULIZA']);
      expect(s.repo.items.map((t) => t.id), ['m1']);
      expect(s.settings.fulizaIds, isEmpty);
      expect(s.settings.handled, hasLength(3));

      // The automatic SMS path still holds Fuliza back.
      final service = SmsImportService(
        gateway: s.gateway,
        settings: s.settings,
        save: (t, key) => s.store.addDetected(t, dedupeKey: key),
      );
      await service.start();
      for (final m in inbox) {
        await service.handle(m);
      }
      expect(s.repo.items.map((t) => t.id),
          unorderedEquals(['m1', 'mpesa_UJMAB1CDC1'])); // the payment only
    });

    test('Undo is scoped to the profile\'s own list', () async {
      // Two profiles on one phone: separate settings, separate stores.
      final a = await setup(inbox);
      final b = await setup(inbox);
      await a.importer.importEligible(await a.importer.preview());
      await b.importer.importEligible(await b.importer.preview());
      await a.importer.undo();
      expect(a.repo.items, isEmpty);
      expect(b.repo.items, hasLength(3));
      expect(b.settings.fulizaIds, hasLength(3));
    });
  });

  group('screen', () {
    testWidgets('shows the preview, imports only after confirming, and '
        'offers Undo', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.8125;
      addTearDown(tester.view.reset);
      // Real async for the setup (it waits for the account stream).
      final s = (await tester.runAsync(() => setup([
            sms(draw('UJMAB1CDD1', '50.00', '0.50'), slot: 0),
            sms(repay('UJMAB1CDD2', '20.00'), slot: 1, minutes: 5),
          ])))!;
      await tester.pumpWidget(
          MaterialApp(home: FulizaImportScreen(importer: s.importer)));
      await tester.pumpAndSettle();
      expect(find.text('Ready to import: 2'), findsOneWidget);
      expect(find.textContaining('SIM 1'), findsWidgets);
      expect(s.repo.writes, isEmpty);

      await tester.scrollUntilVisible(find.text('Import 2'), 200);
      await tester.tap(find.text('Import 2'));
      await tester.pumpAndSettle();
      expect(find.text('Import 2 Fuliza records?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(s.repo.writes, isEmpty);

      await tester.scrollUntilVisible(find.text('Import 2'), 200);
      await tester.tap(find.text('Import 2'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Import'));
      await tester.pumpAndSettle();
      expect(s.repo.writes, hasLength(2));
      expect(find.text('Ready to import: 0'), findsOneWidget);
      expect(find.text('Undo Fuliza import (2)'), findsOneWidget);

      await tester.scrollUntilVisible(find.text('Undo Fuliza import (2)'), 200);
      await tester.tap(find.text('Undo Fuliza import (2)'));
      await tester.pumpAndSettle();
      expect(find.textContaining('delete'), findsWidgets);
      await tester.tap(find.text('Delete 2'));
      await tester.pumpAndSettle();
      expect(s.repo.items, isEmpty);
      expect(find.text('Undo Fuliza import (2)'), findsNothing);
    });
  });
}
