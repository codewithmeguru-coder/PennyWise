import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/accounts/account_repository.dart';
import 'package:pennywise/accounts/money_account.dart';
import 'package:pennywise/data/data_exception.dart';
import 'package:pennywise/data/transaction_store.dart';
import 'package:pennywise/maintenance/account_assignment.dart';
import 'package:pennywise/maintenance/sim_backfill.dart';
import 'package:pennywise/maintenance/ziidi_fix.dart';
import 'package:pennywise/models/fuliza_link.dart';
import 'package:pennywise/models/transaction_model.dart';
import 'package:pennywise/screens/needs_review_screen.dart';
import 'package:pennywise/screens/sim_backfill_screen.dart';
import 'package:pennywise/sms/fuliza_import.dart';
import 'package:pennywise/sms/sms_gateway.dart';
import 'package:pennywise/sms/sms_import_service.dart';
import 'package:pennywise/widgets/transaction_tile.dart';

import 'fake_accounts.dart';
import 'fake_sms.dart';
import 'fake_transaction_repository.dart';

// Needs Review improvements: the "Paid with Fuliza loan" label, giving SMS
// records their account (only the account changes; card impact shown
// first; exact Undo), the previewed SIM backfill, and Fuliza from live SMS
// without duplicates. In memory only. Codes, names and amounts are made up.

final day = DateTime(2026, 10, 20, 9);

String draw(String code, String amount, String fee, String owed) =>
    '$code Confirmed. Fuliza M-PESA amount is Ksh $amount. Access Fee '
    'charged Ksh $fee. Total Fuliza M-PESA outstanding amount is Ksh$owed '
    'due on 21/11/26.';
String repay(String code, String amount) =>
    '$code Confirmed. Ksh $amount from your M-PESA has been used to fully pay '
    'your outstanding Fuliza M-PESA. Available Fuliza M-PESA limit is Ksh '
    '500.00.';
String payment(String code, String amount) =>
    '$code Confirmed. Ksh$amount paid to MAMA PIMA. on 20/10/26 at 9:00 AM.New '
    'M-PESA balance is Ksh0.00. Transaction cost, Ksh0.00.';

TransactionModel sms(
  String id,
  TransactionType type,
  double amount, {
  String category = 'uncategorized',
  String? reference,
  int? simSlot,
  String? accountId,
  String? toAccountId,
  DateTime? date,
  double? fee,
}) => TransactionModel(
  id: id,
  description: 'Item $id',
  amount: amount,
  type: type,
  categoryId: category,
  date: date ?? day,
  source: TransactionSource.mpesa,
  reference: reference ?? id.replaceFirst('mpesa_', ''),
  smsText: 'x',
  account: type == TransactionType.transfer ? null : Account.mpesa,
  toAccount: type == TransactionType.transfer ? Account.mpesa : null,
  accountId: accountId,
  toAccountId: toAccountId,
  simSlot: simSlot,
  fee: fee,
);

/// The starter accounts, not yet loaded (a widget test loads them by
/// pumping; a real delay would never finish under the test clock).
AccountStore accountsUnloaded({DateTime? openingDate}) => AccountStore(
  FakeAccountRepository([
    for (final a in MoneyAccount.starterSet())
      a.id == 'mpesa-sim1' && openingDate != null
          ? a.copyWith(openingBalance: 1000, openingDate: openingDate)
          : a,
  ]),
);

Future<AccountStore> starterAccounts({DateTime? openingDate}) async {
  final accounts = [
    for (final a in MoneyAccount.starterSet())
      a.id == 'mpesa-sim1' && openingDate != null
          ? a.copyWith(openingBalance: 1000, openingDate: openingDate)
          : a,
  ];
  final store = AccountStore(FakeAccountRepository(accounts));
  await Future<void>.delayed(Duration.zero);
  return store;
}

MoneyAccount account(AccountStore s, String id) => s.byId(id)!;

/// The backfill's repository, kept in memory with the same checks as the
/// Firestore one (and updatedAt bumped by every write).
class FakeBackfillRepo implements SimBackfillRepository {
  FakeBackfillRepo(List<ZiidiRecord> records)
    : records = {for (final r in records) r.id: r};

  final Map<String, ZiidiRecord> records;
  final writes = <String>[];
  var _clock = DateTime(2026, 10, 27);

  ZiidiRecord _with(
    ZiidiRecord r, {
    int? simSlot,
    String? accountId,
    String? toAccountId,
    bool clear = false,
    bool clearSim = false,
  }) => ZiidiRecord(
    id: r.id,
    type: r.type,
    category: r.category,
    amount: r.amount,
    date: r.date,
    source: r.source,
    reference: r.reference,
    smsText: r.smsText,
    createdAt: r.createdAt,
    updatedAt: _clock = _clock.add(const Duration(seconds: 1)),
    simSlot: clearSim ? null : (simSlot ?? r.simSlot),
    accountId: clear ? null : (accountId ?? r.accountId),
    toAccountId: clear ? null : (toAccountId ?? r.toAccountId),
  );

  @override
  Future<List<ZiidiRecord>> smsRecords() async => [...records.values];

  @override
  Future<bool> apply(BackfillChange change) async {
    final r = change.record;
    final now = records[r.id];
    if (now == null ||
        now.accountId != null ||
        now.toAccountId != null ||
        now.simSlot != r.simSlot ||
        now.type != r.type ||
        now.category != r.category ||
        now.updatedAt != r.updatedAt) {
      return false;
    }
    writes.add('apply ${r.id}');
    records[r.id] = _with(
      now,
      accountId: change.accountId,
      toAccountId: change.toAccountId,
      simSlot: change.setsSim ? change.simSlot : null,
    );
    return true;
  }

  @override
  Future<bool> undo(
    String id, {
    required String accountId,
    String? toAccountId,
    required bool removeSim,
    required String type,
    required String category,
  }) async {
    final now = records[id];
    if (now == null ||
        now.accountId != accountId ||
        now.toAccountId != toAccountId ||
        now.type != type ||
        now.category != category) {
      return false;
    }
    writes.add('undo $id');
    records[id] = _with(now, clear: true, clearSim: removeSim);
    return true;
  }
}

class MemoryStore implements ZiidiFixStore {
  List<Map<String, Object?>> saved = [];
  Map<String, bool> changedIds = {};
  bool corruptReadBack = false;

  @override
  Future<List<Map<String, Object?>>> backup() async =>
      corruptReadBack ? const [] : [for (final r in saved) Map.of(r)];

  @override
  Future<void> saveBackup(List<Map<String, Object?>> records) async =>
      saved = [for (final r in records) Map.of(r)];

  @override
  Future<Map<String, bool>> changed() async => Map.of(changedIds);

  @override
  Future<void> saveChanged(Map<String, bool> c) async => changedIds = Map.of(c);
}

final created = DateTime(2026, 10, 20, 10);
ZiidiRecord rec(
  String code,
  String type,
  double amount, {
  int? sim,
  String? accountId,
}) => ZiidiRecord(
  id: 'mpesa_$code',
  type: type,
  category: type == 'income' ? 'uncategorized_income' : 'uncategorized',
  amount: amount,
  date: day,
  source: 'mpesa',
  reference: code,
  smsText: payment(code, amount.toStringAsFixed(2)),
  createdAt: created,
  updatedAt: created,
  simSlot: sim,
  accountId: accountId,
);

RawSms inboxSms(String code, int slot) => RawSms(
  sender: 'MPESA',
  body: payment(code, '10.00'),
  date: day,
  simSlot: slot,
);

void main() {
  group('Paid with Fuliza loan', () {
    final loan = sms(
      'mpesa_UFA1B2C3D4_FULIZA',
      TransactionType.transfer,
      100,
      category: 'transfer',
      reference: 'UFA1B2C3D4',
    );
    final paid = sms('mpesa_UFA1B2C3D4', TransactionType.expense, 300);
    final other = sms('mpesa_UFA1B2C3D9', TransactionType.expense, 50);
    final repayment = sms(
      'mpesa_UFA1B2C3D5',
      TransactionType.debtRepayment,
      100,
      category: 'debt_repayment',
    );
    final links = FulizaLinks([loan, paid, other, repayment]);

    test('only a payment sharing a loan\'s code (by the saved keys)', () {
      expect(links.paidWithFuliza(paid), isTrue);
      expect(links.loanFor(paid)!.id, loan.id);
      expect(links.paidWithFuliza(loan), isFalse); // the loan itself
      expect(links.paidWithFuliza(other), isFalse);
      expect(links.paidWithFuliza(repayment), isFalse);
      // Same code but an Airtel record: different source, not linked.
      final airtel = TransactionModel(
        id: 'airtel_UFA1B2C3D4',
        description: 'x',
        amount: 1,
        type: TransactionType.expense,
        categoryId: 'food',
        date: day,
        source: TransactionSource.airtel,
        reference: 'UFA1B2C3D4',
      );
      expect(links.paidWithFuliza(airtel), isFalse);
    });

    testWidgets('the row says so; the category is untouched', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TransactionTile(transaction: paid, paidWithFuliza: true),
          ),
        ),
      );
      expect(find.textContaining('Paid with Fuliza loan'), findsOneWidget);
      expect(paid.categoryId, 'uncategorized');
    });
  });

  group('AccountAssignment', () {
    test('only the account changes', () {
      final t = sms(
        'mpesa_UAC1',
        TransactionType.expense,
        300,
        category: 'food',
        fee: 7,
      );
      final a = t.withAccount('mpesa-sim1');
      expect(a.accountId, 'mpesa-sim1');
      expect(
        [a.id, a.categoryId, a.type, a.amount, a.date, a.fee, a.reference],
        [t.id, t.categoryId, t.type, t.amount, t.date, t.fee, t.reference],
      );
      expect(a.simSlot, isNull);
      expect(
        sms(
          'mpesa_UAC2',
          TransactionType.expense,
          1,
          simSlot: 1,
        ).withAccount('mpesa-sim1', simSlot: 0).simSlot,
        1,
      ); // kept
    });

    test('which records are listed and which can be assigned here', () {
      final noAcc = sms('mpesa_UAC3', TransactionType.expense, 1);
      final transfer = sms('mpesa_UAC4', TransactionType.transfer, 1);
      final has = sms(
        'mpesa_UAC5',
        TransactionType.expense,
        1,
        accountId: 'mpesa-sim1',
      );
      final manual = TransactionModel(
        description: 'm',
        amount: 1,
        type: TransactionType.expense,
        categoryId: 'food',
        date: day,
      );
      expect(
        AccountAssignment.pending([noAcc, transfer, has, manual])
            .map((t) => t.id),
        unorderedEquals([noAcc.id, transfer.id]),
      );
      expect(AccountAssignment.assignable(noAcc), isTrue);
      expect(AccountAssignment.assignable(transfer), isFalse);
    });

    test('card impact: none before the starting balance; the amount and fee '
        'after it; none when already counted through its SIM', () async {
      final accounts = await starterAccounts(openingDate: day);
      final sim1 = account(accounts, 'mpesa-sim1');
      final before = sms(
        'mpesa_UAC6',
        TransactionType.expense,
        100,
        date: day.subtract(const Duration(days: 1)),
      );
      final after = sms(
        'mpesa_UAC7',
        TransactionType.expense,
        100,
        fee: 5,
        date: day.add(const Duration(hours: 1)),
      );
      final simKnown = sms(
        'mpesa_UAC8',
        TransactionType.expense,
        40,
        simSlot: 0,
        date: day.add(const Duration(hours: 2)),
      );
      final all = [before, after, simKnown];
      expect(
        AccountAssignment.impact(accounts.all, all, [
          before.withAccount(sim1.id),
        ]),
        isEmpty,
      );
      expect(
        AccountAssignment.impact(accounts.all, all, [
          after.withAccount(sim1.id),
        ]),
        {sim1: -105},
      );
      expect(
        AccountAssignment.impact(accounts.all, all, [
          simKnown.withAccount(sim1.id),
        ]),
        isEmpty,
      );
      // Income adds.
      final income = sms(
        'mpesa_UAC9',
        TransactionType.income,
        70,
        category: 'uncategorized_income',
        date: day.add(const Duration(hours: 3)),
      );
      expect(
        AccountAssignment.impact(
          accounts.all,
          [...all, income],
          [income.withAccount(sim1.id)],
        ),
        {sim1: 70},
      );
    });

    test('the known SIM\'s wallet is suggested; never a guess', () async {
      final accounts = await starterAccounts();
      expect(
        AccountAssignment.forKnownSim(
          sms('a', TransactionType.expense, 1, simSlot: 1),
          accounts,
        )!.id,
        'mpesa-sim2',
      );
      expect(
        AccountAssignment.forKnownSim(
          sms('b', TransactionType.expense, 1),
          accounts,
        ),
        isNull,
      );
    });
  });

  group('Account tab', () {
    String? effect(WidgetTester tester, String accountId) =>
        tester.widget<Text>(find.byKey(Key('assign-effect-$accountId'))).data;

    Future<(FakeTransactionRepository, AccountStore, List<String>)> show(
      WidgetTester tester,
      List<TransactionModel> records,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final repo = FakeTransactionRepository(records);
      final store = TransactionStore(repo);
      final accounts = accountsUnloaded(openingDate: DateTime(2026, 10, 1));
      final edits = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: NeedsReviewScreen(
            store: store,
            onCorrect: (_, _) async {},
            accounts: accounts,
            onAssign: (before, after) async {
              edits.add('${after.id} ${after.accountId}');
              await store.update(after);
            },
            onEdit: (t) => edits.add('edit ${t.id}'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Account ('));
      await tester.pumpAndSettle();
      return (repo, accounts, edits);
    }

    testWidgets('known SIM: one tap, the card change shown first; only the '
        'account changes', (tester) async {
      final t = sms(
        'mpesa_UAT1',
        TransactionType.expense,
        250,
        category: 'food',
        simSlot: 1,
      );
      final (repo, _, edits) = await show(tester, [t]);
      expect(find.text('Account (1)'), findsOneWidget);
      await tester.tap(find.text('Item mpesa_UAT1'));
      await tester.pumpAndSettle();
      expect(find.text('Use SIM 2 M-Pesa'), findsOneWidget);
      expect(
        find.textContaining(
          'Past total: no change; already counted through '
          'its SIM.\nCard balance: no change.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Use SIM 2 M-Pesa'));
      await tester.pumpAndSettle();
      expect(edits, ['mpesa_UAT1 mpesa-sim2']);
      final saved = repo.items.single;
      expect(saved.accountId, 'mpesa-sim2');
      expect(saved.categoryId, 'food');
      expect(saved.type, TransactionType.expense);
      expect(saved.amount, 250);
      expect(find.text('Account (0)'), findsOneWidget);
    });

    testWidgets('unknown SIM: pick an account, seeing each card\'s change', (
      tester,
    ) async {
      final t = sms(
        'mpesa_UAT2',
        TransactionType.expense,
        80,
        date: DateTime(2026, 10, 15),
      );
      final (repo, _, _) = await show(tester, [t]);
      await tester.tap(find.text('Item mpesa_UAT2'));
      await tester.pumpAndSettle();
      expect(find.textContaining('wasn\'t recorded'), findsOneWidget);
      // SIM 1's card has a starting balance and shows its history, so the
      // past total and the card balance move alike.
      expect(
        effect(tester, 'mpesa-sim1'),
        'Past total: SIM 1 M-Pesa -KSh 80.00 (not a balance change)\n'
        'Card balance: SIM 1 M-Pesa -KSh 80.00',
      );
      await tester.tap(find.text('SIM 1 M-Pesa'));
      await tester.pumpAndSettle();
      expect(repo.items.single.accountId, 'mpesa-sim1');
      expect(repo.items.single.simSlot, isNull); // only the account
    });

    // SIM 2's card has no starting balance and a balance message newer
    // than the record: the card shows that message's balance.
    TransactionModel newerSim2Balance(DateTime date) => TransactionModel(
      id: 'mpesa_UBAL000002',
      description: 'Newer balance',
      amount: 10,
      type: TransactionType.expense,
      categoryId: 'uncategorized',
      date: date,
      source: TransactionSource.mpesa,
      reference: 'UBAL000002',
      smsText: payment(
        'UBAL000002',
        '10.00',
      ).replaceFirst('Ksh0.00', 'Ksh500.00'),
      account: Account.mpesa,
      accountId: 'mpesa-sim2',
      simSlot: 1,
    );

    test('the past total and the card change can differ', () async {
      final accounts = await starterAccounts();
      final t = sms(
        'mpesa_UAT4',
        TransactionType.expense,
        80,
        date: DateTime(2026, 10, 15),
      );
      final all = [t, newerSim2Balance(DateTime(2026, 10, 20))];
      final after = [t.withAccount('mpesa-sim2')];
      expect(
        AccountAssignment.impact(
          accounts.all,
          all,
          after,
        ).map((a, v) => MapEntry(a.id, v)),
        {'mpesa-sim2': -80},
      );
      expect(AccountAssignment.cardChange(accounts.all, all, after), isEmpty);
      // After the newest balance message, it does move the card.
      final later = [t, newerSim2Balance(DateTime(2026, 10, 10))];
      expect(
        AccountAssignment.cardChange(
          accounts.all,
          later,
          after,
        ).map((a, v) => MapEntry(a.id, v)),
        {'mpesa-sim2': -80},
      );
    });

    testWidgets('already in a newer SMS balance: the sheet says the card '
        'won\'t change', (tester) async {
      final t = sms(
        'mpesa_UAT5',
        TransactionType.expense,
        80,
        date: DateTime(2026, 10, 15),
      );
      await show(tester, [t, newerSim2Balance(DateTime(2026, 10, 20))]);
      await tester.tap(find.text('Item mpesa_UAT5'));
      await tester.pumpAndSettle();
      expect(
        effect(tester, 'mpesa-sim2'),
        'Past total: SIM 2 M-Pesa -KSh 80.00 (not a balance change)\n'
        'Card balance: no change; the card uses a newer M-Pesa balance '
        'message, which already includes this transaction.',
      );
      expect(find.text(AssignmentWording.whatChanges), findsOneWidget);
    });

    testWidgets('after the newest SMS balance: the card genuinely changes', (
      tester,
    ) async {
      final t = sms(
        'mpesa_UAT6',
        TransactionType.expense,
        80,
        date: DateTime(2026, 10, 15),
      );
      await show(tester, [t, newerSim2Balance(DateTime(2026, 10, 10))]);
      await tester.tap(find.text('Item mpesa_UAT6'));
      await tester.pumpAndSettle();
      expect(
        effect(tester, 'mpesa-sim2'),
        'Past total: SIM 2 M-Pesa -KSh 80.00 (not a balance change)\n'
        'Card balance: SIM 2 M-Pesa -KSh 80.00',
      );
    });

    testWidgets('opening the sheet and closing it writes nothing', (
      tester,
    ) async {
      final t = sms(
        'mpesa_UAT7',
        TransactionType.expense,
        80,
        category: 'food',
        date: DateTime(2026, 10, 15),
      );
      final (repo, _, edits) = await show(tester, [t]);
      await tester.tap(find.text('Item mpesa_UAT7'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Past total:'), findsWidgets);
      // Dismiss without choosing (as tapping outside or Back does).
      Navigator.of(tester.element(find.text(AssignmentWording.whatChanges)))
          .pop();
      await tester.pumpAndSettle();
      expect(find.text(AssignmentWording.whatChanges), findsNothing);
      expect(edits, isEmpty);
      final saved = repo.items.single;
      expect(saved.accountId, isNull);
      expect(
        [saved.categoryId, saved.type, saved.amount, saved.date],
        ['food', TransactionType.expense, 80, DateTime(2026, 10, 15)],
      );
      expect(find.text('Account (1)'), findsOneWidget);
    });

    testWidgets('a Ziidi deposit with its SIM recorded: one tap sets both '
        'accounts; type, category and amount stay', (tester) async {
      final t = sms(
        'mpesa_UAT8',
        TransactionType.savingsContribution,
        150,
        category: 'savings',
        simSlot: 1,
      );
      final (repo, _, edits) = await show(tester, [t]);
      await tester.tap(find.text('Item mpesa_UAT8'));
      await tester.pumpAndSettle();
      expect(find.textContaining('came to SIM 2'), findsOneWidget);
      expect(find.byKey(const Key('assign-pair-effect')), findsOneWidget);
      await tester.tap(find.textContaining('Use SIM 2 M-Pesa →'));
      await tester.pumpAndSettle();
      expect(edits, ['mpesa_UAT8 mpesa-sim2']);
      final saved = repo.items.single;
      expect([saved.accountId, saved.toAccountId], ['mpesa-sim2', 'ziidi-sim2']);
      expect([saved.type, saved.categoryId, saved.amount], [
        TransactionType.savingsContribution,
        'savings',
        150,
      ]);
    });

    testWidgets('a move needing two accounts opens the form instead', (
      tester,
    ) async {
      final t = sms(
        'mpesa_UAT3',
        TransactionType.transfer,
        500,
        category: 'transfer',
      );
      final (repo, _, edits) = await show(tester, [t]);
      await tester.tap(find.text('Item mpesa_UAT3'));
      await tester.pumpAndSettle();
      expect(find.textContaining('needs both'), findsOneWidget);
      await tester.tap(find.text('Open in the form'));
      await tester.pumpAndSettle();
      expect(edits, ['edit mpesa_UAT3']);
      expect(repo.items.single.accountId, isNull);
    });

    testWidgets('without accounts the screen is the old category list', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: NeedsReviewScreen(
            store: TransactionStore(FakeTransactionRepository()),
            onCorrect: (_, _) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TabBar), findsNothing);
      expect(find.text('All caught up'), findsOneWidget);
    });
  });

  group('SIM backfill', () {
    late FakeBackfillRepo repo;
    late MemoryStore store;
    late AccountStore accounts;

    Future<SimBackfill> make(
      List<ZiidiRecord> records, {
      List<RawSms> inbox = const [],
      List<TransactionModel>? transactions,
    }) async {
      repo = FakeBackfillRepo(records);
      store = MemoryStore();
      accounts = await starterAccounts();
      final gateway = FakeSmsGateway(permissionGranted: true)
        ..inbox.addAll(inbox);
      return SimBackfill(
        repo: repo,
        store: store,
        gateway: gateway,
        accounts: () => accounts,
        transactions: () => transactions ?? const [],
      );
    }

    final stored = rec('UBF0000001', 'expense', 100, sim: 0);
    final fromInbox = rec('UBF0000002', 'income', 60);
    final unknown = rec('UBF0000003', 'expense', 10);
    final transfer = rec('UBF0000004', 'transfer', 500);
    final both = rec('UBF0000005', 'expense', 20);
    final done = rec(
      'UBF0000006',
      'expense',
      5,
      sim: 0,
      accountId: 'mpesa-sim1',
    );

    test('preview reads only; SIM from the record or the inbox, never '
        'guessed', () async {
      final b = await make(
        [stored, fromInbox, unknown, transfer, both, done],
        inbox: [
          inboxSms('UBF0000002', 1),
          inboxSms('UBF0000005', 0),
          inboxSms('UBF0000005', 1), // seen on both SIMs: no answer
        ],
      );
      final p = await b.preview();
      expect(repo.writes, isEmpty);
      expect(store.saved, isEmpty);
      expect(
        {for (final c in p.changes) c.record.id: c.accountId},
        {stored.id: 'mpesa-sim1', fromInbox.id: 'mpesa-sim2'},
      );
      expect(p.count(SimEvidence.stored), 1);
      expect(p.count(SimEvidence.inbox), 1);
      expect(p.skipped['SIM unknown (not in this phone\'s messages)'], 2);
      expect(p.skipped['Needs two accounts: edit it in the form'], 1);
      expect(p.changes.any((c) => c.record.id == done.id), isFalse);
    });

    test('apply: backup first, then only account (and missing SIM); '
        'category and type unchanged', () async {
      final b = await make(
        [stored, fromInbox],
        inbox: [inboxSms('UBF0000002', 1)],
      );
      final r = await b.apply(await b.preview());
      expect(r.done, 2);
      expect(
        store.saved.map((s) => s['id']),
        unorderedEquals([stored.id, fromInbox.id]),
      );
      final a = repo.records[stored.id]!, c = repo.records[fromInbox.id]!;
      expect(a.accountId, 'mpesa-sim1');
      expect(a.simSlot, 0);
      expect(c.accountId, 'mpesa-sim2');
      expect(c.simSlot, 1); // was missing, now set from the inbox
      expect(
        [a.type, a.category, c.type, c.category],
        ['expense', 'uncategorized', 'income', 'uncategorized_income'],
      );
    });

    test('a record changed since the preview is skipped', () async {
      final b = await make([stored]);
      final p = await b.preview();
      repo.records[stored.id] = ZiidiRecord(
        id: stored.id,
        type: 'expense',
        category: 'food',
        amount: stored.amount,
        date: stored.date,
        source: 'mpesa',
        reference: stored.reference,
        simSlot: 0,
        createdAt: created,
        updatedAt: created.add(const Duration(minutes: 1)),
      );
      final r = await b.apply(p);
      expect(r.done, 0);
      expect(r.skipped, 1);
      expect(repo.records[stored.id]!.accountId, isNull);
    });

    test('a backup that cannot be checked stops before any write', () async {
      final b = await make([stored]);
      store.corruptReadBack = true;
      final r = await b.apply(await b.preview());
      expect(r.error, contains('backup'));
      expect(repo.writes, isEmpty);
    });

    test('Undo removes exactly what it set; edited ones are left', () async {
      final b = await make(
        [stored, fromInbox],
        inbox: [inboxSms('UBF0000002', 1)],
      );
      await b.apply(await b.preview());
      // The user re-categorises one afterwards.
      final e = repo.records[fromInbox.id]!;
      repo.records[e.id] = ZiidiRecord(
        id: e.id,
        type: e.type,
        category: 'salary',
        amount: e.amount,
        date: e.date,
        source: e.source,
        reference: e.reference,
        simSlot: e.simSlot,
        accountId: e.accountId,
        createdAt: e.createdAt,
        updatedAt: e.updatedAt,
      );
      final r = await b.undo();
      expect(r.done, 1);
      expect(r.skipped, 1);
      expect(repo.records[stored.id]!.accountId, isNull);
      expect(repo.records[stored.id]!.simSlot, 0); // it had its SIM already
      expect(repo.records[fromInbox.id]!.accountId, 'mpesa-sim2');
    });

    test('each group is applied on its own, with its own card changes; '
        'only the account (and missing SIM) changes', () async {
      final t = sms(
        'mpesa_UBF0000001',
        TransactionType.expense,
        100,
        simSlot: 0,
      );
      final income = sms(
        'mpesa_UBF0000002',
        TransactionType.income,
        60,
        category: 'uncategorized_income',
      );
      final b = await make(
        [stored, fromInbox],
        inbox: [inboxSms('UBF0000002', 1)],
        transactions: [t, income],
      );
      final p = await b.preview();
      final known = p.only(SimEvidence.stored);
      final inbox = p.only(SimEvidence.inbox);
      expect(known.changes.map((c) => c.record.id), [stored.id]);
      expect(known.impact, isEmpty); // already counted through its SIM
      expect(known.changes.single.accountName, isNotNull);
      expect(inbox.changes.map((c) => c.record.id), [fromInbox.id]);
      expect(inbox.impact.map((a, v) => MapEntry(a.id, v)), {'mpesa-sim2': 60});

      final before = {for (final r in repo.records.values) r.id: r};
      final r = await b.apply(known);
      expect(r.done, 1);
      expect(repo.writes, ['apply ${stored.id}']);
      expect(repo.records[fromInbox.id]!.accountId, isNull); // other group
      final a = repo.records[stored.id]!, was = before[stored.id]!;
      expect(
        [a.type, a.category, a.amount, a.date, a.reference, a.simSlot],
        [was.type, was.category, was.amount, was.date, was.reference, 0],
      );
      expect(a.accountId, 'mpesa-sim1');
    });

    group('wording: past totals vs card balances', () {
      // SIM 2's card has no starting balance and a newer M-Pesa balance
      // message, so it shows that balance: older records don't move it.
      TransactionModel newerBalance() => TransactionModel(
        id: 'mpesa_UBAL000001',
        description: 'Newer balance',
        amount: 10,
        type: TransactionType.expense,
        categoryId: 'uncategorized',
        date: day.add(const Duration(days: 1)),
        source: TransactionSource.mpesa,
        reference: 'UBAL000001',
        smsText: payment(
          'UBAL000001',
          '10.00',
        ).replaceFirst('Ksh0.00', 'Ksh500.00'),
        account: Account.mpesa,
        accountId: 'mpesa-sim2',
        simSlot: 1,
      );
      final storedTx = sms(
        'mpesa_UBF0000001',
        TransactionType.expense,
        100,
        simSlot: 0,
      );
      final incomeTx = sms(
        'mpesa_UBF0000002',
        TransactionType.income,
        60,
        category: 'uncategorized_income',
      );

      Future<SimBackfill> withCards({required bool newerSms}) => make(
        [stored, fromInbox],
        inbox: [inboxSms('UBF0000002', 1)],
        transactions: [storedTx, incomeTx, if (newerSms) newerBalance()],
      );

      test('past totals are kept apart from the card balance change', () async {
        final p = await (await withCards(newerSms: true)).preview();
        final inbox = p.only(SimEvidence.inbox);
        // History: SIM 2 gains this income in its past total...
        expect(inbox.impact.map((a, v) => MapEntry(a.id, v)), {
          'mpesa-sim2': 60,
        });
        // ...but the card shows the newer SMS balance: no change.
        expect(inbox.cardChange, isEmpty);
        expect(p.cardChange, isEmpty);
        expect(
          BackfillWording.cards(inbox),
          'No change. Your cards use newer M-Pesa balance messages, which '
          'already include these transactions.',
        );
        expect(BackfillWording.history(inbox), contains('+'));
        expect(BackfillWording.history(inbox), contains('60'));
      });

      test('records already counted: no past or card change', () async {
        final p = await (await withCards(newerSms: true)).preview();
        final known = p.only(SimEvidence.stored);
        expect(known.impact, isEmpty);
        expect(known.cardChange, isEmpty);
        expect(
          BackfillWording.history(known),
          'None. These are already counted on their account.',
        );
        expect(
          BackfillWording.cards(known),
          'No change. These are already counted in their account balances.',
        );
      });

      test(
        'a card that shows its history does change, and says by how much',
        () async {
          final p = await (await withCards(newerSms: false)).preview();
          final inbox = p.only(SimEvidence.inbox);
          expect(inbox.cardChange.map((a, v) => MapEntry(a.id, v)), {
            'mpesa-sim2': 60,
          });
          expect(BackfillWording.cards(inbox), isNot(startsWith('No change')));
          expect(BackfillWording.cards(inbox), contains('60'));
        },
      );

      testWidgets('the screen labels each figure plainly; nothing is '
          'written by looking', (tester) async {
        // Tall enough for both groups to be built.
        tester.view.physicalSize = const Size(1080, 6000);
        addTearDown(tester.view.reset);
        final b = (await tester.runAsync(() => withCards(newerSms: true)))!;
        await tester.pumpWidget(
          MaterialApp(home: SimBackfillScreen(backfill: b)),
        );
        await tester.pumpAndSettle();
        expect(find.text(BackfillWording.whatChanges), findsOneWidget);
        expect(find.text(BackfillWording.historyTitle), findsNWidgets(2));
        expect(find.text(BackfillWording.cardsTitle), findsNWidgets(2));
        expect(
          tester
              .widget<Text>(find.byKey(const Key('backfill-inbox-cards')))
              .data,
          startsWith('No change. Your cards use newer M-Pesa balance'),
        );
        expect(
          tester
              .widget<Text>(find.byKey(const Key('backfill-stored-cards')))
              .data,
          startsWith('No change. These are already counted'),
        );
        expect(find.textContaining('would change by'), findsNothing);
        expect(repo.writes, isEmpty);
        expect(store.saved, isEmpty);

        // The confirmation repeats both figures; Cancel writes nothing.
        await tester.scrollUntilVisible(
          find.text('Back up and assign 1').last,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text('Back up and assign 1').last);
        await tester.pumpAndSettle();
        expect(find.textContaining(BackfillWording.whatChanges), findsWidgets);
        expect(
          find.textContaining('No change. Your cards use newer'),
          findsWidgets,
        );
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(repo.writes, isEmpty);
        expect(store.saved, isEmpty);
      });
    });

    test('a Ziidi deposit with its SIM in the inbox gets both accounts; '
        'Undo removes both', () async {
      final ziidi = rec('UBF0000009', 'savings_contribution', 50);
      final b = await make([ziidi], inbox: [inboxSms('UBF0000009', 1)]);
      final p = await b.preview();
      final c = p.changes.single;
      expect([c.accountId, c.toAccountId, c.simSlot], [
        'mpesa-sim2',
        'ziidi-sim2',
        1,
      ]);
      await b.apply(p);
      final saved = repo.records[ziidi.id]!;
      expect([saved.accountId, saved.toAccountId, saved.simSlot], [
        'mpesa-sim2',
        'ziidi-sim2',
        1,
      ]);
      expect([saved.type, saved.category], [ziidi.type, ziidi.category]);
      final r = await b.undo();
      expect(r.done, 1);
      final back = repo.records[ziidi.id]!;
      expect([back.accountId, back.toAccountId, back.simSlot], [
        null,
        null,
        null,
      ]);
    });

    test('a transfer still goes to the form, whatever its SIM', () async {
      final t = rec('UBF0000010', 'transfer', 500, sim: 0);
      final p = await (await make([t])).preview();
      expect(p.changes, isEmpty);
      expect(p.skipped['Needs two accounts: edit it in the form'], 1);
    });

    test('the preview says how each card would move', () async {
      final t = sms(
        'mpesa_UBF0000001',
        TransactionType.expense,
        100,
        simSlot: 0,
      );
      final income = sms(
        'mpesa_UBF0000002',
        TransactionType.income,
        60,
        category: 'uncategorized_income',
      );
      final b = await make(
        [stored, fromInbox],
        inbox: [inboxSms('UBF0000002', 1)],
        transactions: [t, income],
      );
      final p = await b.preview();
      // SIM 1's was already counted through its SIM; SIM 2 gains 60.
      expect(p.impact.map((a, v) => MapEntry(a.id, v)), {'mpesa-sim2': 60});
    });
  });

  group('Fuliza from live SMS', () {
    late List<String> saved;
    late FakeSmsSettings settings;

    Future<SmsImportService> service({
      AccountStore? accounts,
      bool autoFuliza = true, // turned on by the user in Settings
      List<RawSms> inbox = const [],
    }) async {
      saved = [];
      settings = FakeSmsSettings(enabled: true)..autoFuliza = autoFuliza;
      final s = SmsImportService(
        gateway: FakeSmsGateway(permissionGranted: true)..inbox.addAll(inbox),
        settings: settings,
        accounts: () => accounts,
        save: (t, key) async {
          if (saved.contains(key)) return false; // create-if-absent
          saved.add(key);
          return true;
        },
      );
      await s.start(); // detection on, as on the phone
      return s;
    }

    RawSms msg(String body, {int? slot = 0}) =>
        RawSms(sender: 'MPESA', body: body, date: day, simSlot: slot);

    test('a loan and a repayment are saved on that SIM\'s accounts, under '
        'the same keys as the history import', () async {
      final s = await service(accounts: await starterAccounts());
      final loan = await s.handle(
        msg(draw('UFL0000001', '50.00', '0.50', '50.50')),
      );
      expect(saved, ['mpesa_UFL0000001_FULIZA']);
      expect(loan!.accountId, 'fuliza-sim1');
      expect(loan.toAccountId, 'mpesa-sim1');
      expect(loan.fee, 0.5);
      final back = await s.handle(msg(repay('UFL0000002', '50.50')));
      expect(back!.type, TransactionType.debtRepayment);
      expect(back.accountId, 'mpesa-sim1');
      expect(back.toAccountId, 'fuliza-sim1');
    });

    test('the same message again, or one the history import already '
        'brought in, is never saved twice', () async {
      final s = await service(accounts: await starterAccounts());
      final m = msg(draw('UFL0000003', '20.00', '0.20', '20.20'));
      await s.handle(m);
      expect(await s.handle(m), isNull);
      expect(saved, hasLength(1));
      // Marked handled by the history import: not saved again.
      await settings.addHandledKey('mpesa_UFL0000004_FULIZA');
      expect(
        await s.handle(msg(draw('UFL0000004', '10.00', '0.10', '10.10'))),
        isNull,
      );
      expect(saved, hasLength(1));
    });

    test('the payment a loan completed is saved separately, once', () async {
      final s = await service(accounts: await starterAccounts());
      await s.handle(msg(payment('UFL0000005', '300.00')));
      await s.handle(msg(draw('UFL0000005', '100.00', '1.00', '101.00')));
      expect(saved, ['mpesa_UFL0000005', 'mpesa_UFL0000005_FULIZA']);
    });

    test('off by default: installing or opening the app saves no Fuliza, '
        'and holds the messages for the history import', () async {
      expect(await FakeSmsSettings().autoFulizaImport(), isFalse);
      // Fuliza messages already on the phone when the app is installed.
      final s = await service(
        accounts: await starterAccounts(),
        autoFuliza: false,
        inbox: [
          msg(draw('UFL0000013', '40.00', '0.40', '40.40')),
          msg(repay('UFL0000014', '40.40')),
        ],
      );
      // Opening, returning to, and scanning: nothing Fuliza is saved.
      await s.onAppResumed();
      await s.scanRecent(days: 3650);
      expect(saved, isEmpty);
      expect(
        await s.handle(msg(draw('UFL0000008', '50.00', '0.50', '50.50'))),
        isNull,
      );
      expect(await s.handle(msg(repay('UFL0000009', '50.50'))), isNull);
      expect(saved, isEmpty);
      expect(
        (await settings.skippedCounts())[SkipReason.fulizaWaiting],
        greaterThanOrEqualTo(2),
      );
      // Not marked handled: the history import can still bring them in.
      expect(
        await settings.handledKeys(),
        isNot(contains('mpesa_UFL0000008_FULIZA')),
      );
      // Ordinary M-Pesa messages are still saved as before.
      expect(await s.handle(msg(payment('UFL0000010', '30.00'))), isNotNull);
      expect(saved, ['mpesa_UFL0000010']);
    });

    test(
      'only after the user turns it on are new Fuliza messages saved',
      () async {
        final s = await service(
          accounts: await starterAccounts(),
          autoFuliza: false,
        );
        final m = msg(draw('UFL0000011', '50.00', '0.50', '50.50'));
        expect(await s.handle(m), isNull);
        await s.setAutoFulizaImport(true);
        expect(settings.autoFuliza, isTrue);
        expect(await s.handle(m), isNotNull);
        expect(saved, ['mpesa_UFL0000011_FULIZA']);
        await s.setAutoFulizaImport(false);
        expect(
          await s.handle(msg(draw('UFL0000012', '5.00', '0.05', '5.05'))),
          isNull,
        );
        expect(saved, hasLength(1));
      },
    );

    test(
      'unknown SIM or no accounts: held, not guessed, not handled',
      () async {
        final s = await service(accounts: await starterAccounts());
        expect(
          await s.handle(
            msg(draw('UFL0000006', '5.00', '0.05', '5.05'), slot: null),
          ),
          isNull,
        );
        final noAccounts = await service();
        expect(
          await noAccounts.handle(
            msg(draw('UFL0000007', '5.00', '0.05', '5.05')),
          ),
          isNull,
        );
        expect(saved, isEmpty);
        expect(
          await settings.handledKeys(),
          isNot(contains('mpesa_UFL0000007_FULIZA')),
        );
        expect((await settings.skippedCounts())[SkipReason.fulizaNoAccount], 1);
      },
    );
  });

  group('Fuliza catch-up preview', () {
    test('only new records, under their keys; payments already saved are '
        'counted, never added', () async {
      final accounts = await starterAccounts();
      final existing = [
        sms('mpesa_UFC0000001', TransactionType.expense, 100),
        sms(
          'mpesa_UFC0000002_FULIZA',
          TransactionType.transfer,
          30,
          reference: 'UFC0000002',
          category: 'transfer',
        ),
      ];
      final importer = FulizaImporter(
        gateway: FakeSmsGateway(permissionGranted: true)
          ..inbox.addAll([
            RawSms(
              sender: 'MPESA',
              date: day,
              simSlot: 0,
              body: draw('UFC0000001', '100.00', '1.00', '101.00'),
            ),
            RawSms(
              sender: 'MPESA',
              date: day,
              simSlot: 0,
              body: draw('UFC0000002', '30.00', '0.30', '131.30'),
            ),
            RawSms(
              sender: 'MPESA',
              date: day,
              simSlot: 0,
              body: draw('UFC0000001', '100.00', '1.00', '101.00'),
            ),
          ]),
        settings: FakeSmsSettings(enabled: true),
        accounts: () => accounts,
        existingIds: () => {for (final t in existing) t.id},
        save: (_, _) async => throw StateError('preview must not write'),
        delete: (_) async => throw StateError('preview must not delete'),
      );
      final p = await importer.preview();
      expect(p.toCreate.map((t) => t.id), ['mpesa_UFC0000001_FULIZA']);
      expect(p.count(FulizaStatus.alreadyImported), 1);
      expect(p.count(FulizaStatus.repeated), 1);
      expect(p.withPaymentSaved, 1);
      // Cards: SIM 1 M-Pesa +100 (borrowed); the fee is added to what
      // Fuliza is owed, so Fuliza goes to −101.
      final cards = AccountAssignment.impact(
        accounts.all,
        existing,
        p.toCreate,
      ).map((a, v) => MapEntry(a.id, v));
      expect(cards, {'mpesa-sim1': 100, 'fuliza-sim1': -101});
    });
  });

  test('a failed account save keeps the record as it was', () async {
    final repo = FakeTransactionRepository([
      sms('mpesa_UAF1', TransactionType.expense, 10),
    ])..loadError = null;
    final store = TransactionStore(repo);
    await Future<void>.delayed(Duration.zero);
    final before = store.transactions.single;
    final failing = _FailingRepo([before]);
    final s2 = TransactionStore(failing);
    await Future<void>.delayed(Duration.zero);
    expect(
      () => s2.update(before.withAccount('mpesa-sim1')),
      throwsA(isA<DataException>()),
    );
    expect(failing.items.single.accountId, isNull);
  });
}

class _FailingRepo extends FakeTransactionRepository {
  _FailingRepo(super.initial);

  @override
  Future<void> update(TransactionModel t) async =>
      throw const DataException('No connection.');
}
