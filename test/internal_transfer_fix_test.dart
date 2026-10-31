import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/accounts/account_repository.dart';
import 'package:pennywise/accounts/money_account.dart';
import 'package:pennywise/maintenance/internal_transfer_fix.dart';
import 'package:pennywise/models/transaction_model.dart';
import 'package:pennywise/screens/move_fix_screen.dart';
import 'package:pennywise/sms/sms_gateway.dart';

import 'fake_accounts.dart';
import 'fake_sms.dart';

// "Fix moves between your SIMs": money moved between the user's own SIMs
// (sent on one, received on the other) or withdrawn as cash, saved as
// spending or income, becomes a transfer. In memory only; codes, names and
// amounts are made up.

final day = DateTime(2026, 9, 14, 9);
final created = DateTime(2026, 10, 6, 16);

String sent(String code, String amount, String cost) =>
    '$code Confirmed. Ksh$amount sent to PAT OWNER 0722334455 on 14/9/26 at '
    '9:00 AM. New M-PESA balance is Ksh200.00. Transaction cost, Ksh$cost.';
String received(String code, String amount) =>
    '$code Confirmed.You have received Ksh$amount from PAT OWNER 0711223344 '
    'on 14/9/26 at 9:00 AM New M-PESA balance is Ksh900.00.';
String withdrawn(String code, String amount, String cost) =>
    '$code Confirmed.on 14/9/26 at 9:00 AMWithdraw Ksh$amount from 123456 - '
    'MAMA MBOGA AGENCIES New M-PESA balance is Ksh37.12. Transaction cost, '
    'Ksh$cost.';
String paid(String code, String amount) =>
    '$code Confirmed. Ksh$amount paid to MAMA PIMA. on 14/9/26 at 9:00 AM.New '
    'M-PESA balance is Ksh0.00. Transaction cost, Ksh0.00.';

RawSms sms(String body, int slot, {DateTime? at}) =>
    RawSms(sender: 'MPESA', body: body, date: at ?? day, simSlot: slot);

MoveRecord rec(
  String code,
  String type,
  double amount, {
  String category = 'uncategorized',
  String? accountId,
  int? simSlot,
  double? fee,
  String? account,
}) => MoveRecord(
  id: 'mpesa_$code',
  type: type,
  category: category,
  amount: amount,
  date: day,
  reference: code,
  accountId: accountId,
  simSlot: simSlot,
  fee: fee,
  account: account,
  updatedAt: created,
);

TransactionModel txOf(MoveRecord r) => TransactionModel(
  id: r.id,
  description: 'Item ${r.reference}',
  amount: r.amount,
  type: TransactionType.fromWire(r.type)!,
  categoryId: r.category,
  date: r.date,
  source: TransactionSource.mpesa,
  reference: r.reference,
  account: Account.fromWire(r.account),
  accountId: r.accountId,
  simSlot: r.simSlot,
  fee: r.fee,
);

/// The repository in memory, with the same checks as the Firestore one.
class FakeMoveRepo implements MoveFixRepository {
  FakeMoveRepo(List<MoveRecord> records)
    : records = {for (final r in records) r.id: r};

  final Map<String, MoveRecord> records;
  final writes = <String>[];
  var _clock = DateTime(2026, 10, 27);

  /// The app is killed just before / just after the next record's write.
  bool killBeforeWrite = false, killAfterWrite = false;

  DateTime tick() => _clock = _clock.add(const Duration(seconds: 1));

  /// The user edits a fixed record later (a save stamps updatedAt).
  void userEdit(String id, {double? fee, int? simSlot, DateTime? date}) {
    final r = records[id]!;
    records[id] = MoveRecord(
      id: r.id,
      type: r.type,
      category: r.category,
      amount: r.amount,
      date: date ?? r.date,
      reference: r.reference,
      account: r.account,
      toAccount: r.toAccount,
      accountId: r.accountId,
      toAccountId: r.toAccountId,
      simSlot: simSlot ?? r.simSlot,
      fee: fee ?? r.fee,
      hasMarker: r.hasMarker,
      markerAt: r.markerAt,
      updatedAt: tick(),
    );
  }

  @override
  Future<List<MoveRecord>> smsRecords() async => [...records.values];

  @override
  Future<bool> apply(MoveChange c) async {
    final now = records[c.record.id];
    if (now == null || !MoveFix.sameAsPreview(now, c.record)) return false;
    if (killBeforeWrite) throw StateError('app killed');
    writes.add('apply ${c.record.id}');
    final at = tick();
    records[now.id] = MoveRecord(
      id: now.id,
      type: 'transfer',
      category: 'transfer',
      amount: now.amount,
      date: now.date,
      reference: now.reference,
      account: 'mpesa',
      toAccount: c.toAccount,
      accountId: c.accountId,
      toAccountId: c.toAccountId,
      simSlot: c.fromSim,
      fee: c.addFee ?? now.fee,
      hasMarker: true,
      markerAt: at,
      updatedAt: at,
    );
    if (killAfterWrite) throw StateError('app killed');
    return true;
  }

  @override
  Future<UndoOutcome> undo(MoveRecord original, MoveChange c) async {
    final found = records[original.id];
    final outcome = MoveFix.undoOutcome(found, c);
    if (outcome != UndoOutcome.undone) return outcome;
    final now = found!;
    writes.add('undo ${original.id}');
    records[original.id] = MoveRecord(
      id: original.id,
      type: original.type,
      category: original.category,
      amount: now.amount,
      date: now.date,
      reference: now.reference,
      account: original.account,
      toAccount: original.toAccount,
      accountId: original.accountId,
      toAccountId: original.toAccountId,
      simSlot: original.simSlot,
      fee: original.fee,
      updatedAt: tick(),
    );
    return UndoOutcome.undone;
  }
}

class MemoryStore implements MoveFixStore {
  List<Map<String, Object?>> saved = [];
  Map<String, bool> changedIds = {};
  List<String> lines = [];
  bool corruptReadBack = false, failSaveBackup = false, failSaveChanged = false;

  @override
  Future<List<String>> log() async => [...lines];

  @override
  Future<void> saveLog(List<String> l) async => lines = [...l];

  @override
  Future<List<Map<String, Object?>>> backup() async =>
      corruptReadBack ? const [] : [for (final r in saved) Map.of(r)];

  @override
  Future<void> saveBackup(List<Map<String, Object?>> records) async {
    if (failSaveBackup) throw StateError('storage full');
    saved = [for (final r in records) Map.of(r)];
  }

  @override
  Future<Map<String, bool>> changed() async => Map.of(changedIds);

  @override
  Future<void> saveChanged(Map<String, bool> changed) async {
    if (failSaveChanged) throw StateError('storage full');
    changedIds = Map.of(changed);
  }
}

void main() {
  late FakeMoveRepo repo;
  late MemoryStore store;

  // SIM 2 -> SIM 1 (expense with a 90 charge), SIM 1 -> SIM 2 seen from the
  // receiving side (income), an agent withdrawal on SIM 1, an ordinary
  // payment, and a code seen on one SIM only.
  final move = rec('UMV0000001', 'expense', 8000);
  final back = rec('UMV0000002', 'income', 100, category: 'money_received');
  final cashOut = rec(
    'UMV0000003',
    'expense',
    1250,
    category: 'cash_withdrawal',
  );
  final shop = rec('UMV0000004', 'expense', 300, category: 'food');
  final oneSim = rec('UMV0000005', 'expense', 500);
  List<RawSms> inbox() => [
    sms(sent('UMV0000001', '8,000.00', '90.00'), 1),
    sms(received('UMV0000001', '8,000.00'), 0),
    sms(sent('UMV0000002', '100.00', '0.00'), 0),
    sms(received('UMV0000002', '100.00'), 1),
    sms(withdrawn('UMV0000003', '1,250.00', '29.00'), 0),
    sms(paid('UMV0000004', '300.00'), 0),
    sms(sent('UMV0000005', '500.00', '7.00'), 1),
  ];

  Future<AccountStore> accounts({DateTime? cashStart}) async {
    final list = [
      for (final a in MoneyAccount.starterSet())
        a.id == 'cash' && cashStart != null
            ? a.copyWith(openingBalance: 0, openingDate: cashStart)
            : a,
    ];
    final s = AccountStore(FakeAccountRepository(list));
    await Future<void>.delayed(Duration.zero);
    return s;
  }

  Future<MoveFix> make(
    List<MoveRecord> records, {
    AccountStore? accountStore,
    List<RawSms>? messages,
    bool restart = false,
  }) async {
    if (!restart) {
      repo = FakeMoveRepo(records);
      store = MemoryStore();
    }
    final acc =
        accountStore ?? await accounts(cashStart: DateTime(2026, 10, 27));
    final gateway = FakeSmsGateway(permissionGranted: true)
      ..inbox.addAll(messages ?? inbox());
    return MoveFix(
      repository: repo,
      store: store,
      gateway: gateway,
      accounts: () => acc,
      transactions: () => [for (final r in repo.records.values) txOf(r)],
    );
  }

  test('preview reads only; proposes only moves both SIMs saw, and agent '
      'withdrawals', () async {
    final f = await make([move, back, cashOut, shop, oneSim]);
    final p = await f.preview();
    expect(repo.writes, isEmpty);
    expect(store.saved, isEmpty);
    expect(
      {for (final c in p.changes) c.record.id: c.kind},
      {
        move.id: MoveKind.betweenSims,
        back.id: MoveKind.betweenSims,
        cashOut.id: MoveKind.cashWithdrawal,
      },
    );
    final m = p.changes.firstWhere((c) => c.record.id == move.id);
    expect(
      [m.fromSim, m.toSim, m.accountId, m.toAccountId],
      [1, 0, 'mpesa-sim2', 'mpesa-sim1'],
    );
    expect(m.toAccount, isNull); // two M-Pesa lines: ids only
    expect(m.addFee, 90);
    final b = p.changes.firstWhere((c) => c.record.id == back.id);
    expect(
      [b.accountId, b.toAccountId, b.addFee],
      ['mpesa-sim1', 'mpesa-sim2', null],
    );
    final w = p.changes.firstWhere((c) => c.record.id == cashOut.id);
    expect(
      [w.accountId, w.toAccountId, w.toAccount, w.addFee],
      ['mpesa-sim1', 'cash', 'cash', 29],
    );
    expect(p.feesAdded, 119);
  });

  test(
    'the effect: transfers leave spending and income; fees count once',
    () async {
      final f = await make([move, back, cashOut, shop]);
      final p = await f.preview();
      final sep = p.months.single;
      expect(sep.before.expenses, 9550); // 8000 + 1250 + 300
      expect(sep.after.expenses, 300 + 90 + 29); // shop + the two charges
      expect(sep.before.income, 100);
      expect(sep.after.income, 0);
      // Cash starts after the withdrawal, so its card doesn't move.
      expect(p.cards.keys.map((a) => a.id), isNot(contains('cash')));
    },
  );

  test('a fee already counted is not added again', () async {
    final counted = rec(
      'UMV0000001',
      'expense',
      8000,
      accountId: 'mpesa-sim2',
      simSlot: 1,
      fee: 90,
      account: 'mpesa',
    );
    final p = await (await make([counted])).preview();
    expect(p.changes.single.addFee, isNull);
    expect(p.feesAdded, 0);
  });

  test('a cash withdrawal waits until Cash has a starting balance dated '
      'after it', () async {
    for (final start in [null, DateTime(2026, 9, 1)]) {
      final f = await make([
        cashOut,
      ], accountStore: await accounts(cashStart: start));
      final p = await f.preview();
      expect(p.changes, isEmpty, reason: '$start');
      expect(p.blocked.single.record.id, cashOut.id);
    }
  });

  test('amounts that differ from the messages are left alone', () async {
    final f = await make([rec('UMV0000001', 'expense', 7000)]);
    final p = await f.preview();
    expect(p.changes, isEmpty);
    expect(p.skipped['Amounts differ from the messages'], 1);
  });

  test('apply: backup first; only type, category, accounts, SIM and a '
      'missing fee change', () async {
    final f = await make([move, back, cashOut]);
    final r = await f.apply(await f.preview());
    expect(r.done, 3);
    expect(store.saved.map((s) => s['id']), containsAll([move.id, cashOut.id]));
    final m = repo.records[move.id]!;
    expect(
      [m.type, m.category, m.account, m.toAccount, m.accountId],
      ['transfer', 'transfer', 'mpesa', null, 'mpesa-sim2'],
    );
    expect(
      [m.toAccountId, m.simSlot, m.fee, m.hasMarker],
      ['mpesa-sim1', 1, 90, true],
    );
    expect([m.amount, m.date, m.reference], [8000, day, 'UMV0000001']);
    final w = repo.records[cashOut.id]!;
    expect([w.toAccount, w.toAccountId, w.fee], ['cash', 'cash', 29]);
    expect(r.log, contains('${move.id}: fixed'));
  });

  test('a record changed since the preview is left alone', () async {
    final f = await make([move]);
    final p = await f.preview();
    repo.records[move.id] = rec(
      'UMV0000001',
      'expense',
      8000,
      category: 'food',
    );
    final r = await f.apply(p);
    expect(r.done, 0);
    expect(r.skipped, 1);
    expect(repo.records[move.id]!.type, 'expense');
  });

  test('running it twice changes nothing more', () async {
    final f = await make([move, back]);
    await f.apply(await f.preview());
    final writes = repo.writes.length;
    final again = await f.preview();
    expect(again.changes, isEmpty); // already transfers, with the marker
    expect((await f.apply(again)).done, 0);
    expect(repo.writes.length, writes);
  });

  test('a backup that cannot be checked stops before any write', () async {
    final f = await make([move]);
    store.corruptReadBack = true;
    final r = await f.apply(await f.preview());
    expect(r.error, contains('backup'));
    expect(repo.writes, isEmpty);
  });

  test('Undo puts every field back exactly, including ones that were '
      'missing; edited records are left', () async {
    final had = rec(
      'UMV0000002',
      'income',
      100,
      category: 'money_received',
      accountId: 'mpesa-sim2',
      simSlot: 1,
      fee: 3,
      account: 'mpesa',
    );
    final f = await make([move, had, cashOut]);
    await f.apply(await f.preview());
    // The user re-categorises the withdrawal afterwards.
    final w = repo.records[cashOut.id]!;
    repo.records[w.id] = MoveRecord(
      id: w.id,
      type: 'expense',
      category: 'shopping',
      amount: w.amount,
      date: w.date,
      reference: w.reference,
      hasMarker: true,
    );
    final r = await f.undo();
    expect(r.done, 2);
    expect(r.skipped, 1);
    final m = repo.records[move.id]!;
    expect(
      [m.type, m.category, m.account, m.toAccount, m.accountId, m.simSlot],
      ['expense', 'uncategorized', null, null, null, null],
    );
    expect([m.toAccountId, m.fee, m.hasMarker], [null, null, false]);
    final h = repo.records[had.id]!;
    expect(
      [h.type, h.accountId, h.simSlot, h.fee, h.account],
      ['income', 'mpesa-sim2', 1, 3, 'mpesa'],
    );
    expect(repo.records[cashOut.id]!.category, 'shopping');
    expect(await f.changedIds(), isEmpty);
  });

  group('crash safety (Gap A)', () {
    test(
      'each record is on the Undo list as pending before its write',
      () async {
        final f = await make([move]);
        final p = await f.preview();
        repo.killBeforeWrite = true;
        await expectLater(f.apply(p), throwsStateError);
        expect(store.changedIds, {move.id: false});
        expect(repo.writes, isEmpty);
      },
    );

    test('killed just after a write: Undo still reaches it and puts it '
        'back', () async {
      final f = await make([move, back]);
      final p = await f.preview();
      repo.killAfterWrite = true;
      await expectLater(f.apply(p), throwsStateError);
      expect(repo.records[move.id]!.type, 'transfer'); // written
      expect(store.changedIds[move.id], false); // still only pending
      // The app starts again: a resumed run doesn't apply it twice...
      repo.killAfterWrite = false;
      final again = await make([], restart: true);
      final p2 = await again.preview();
      expect(p2.changes.map((c) => c.record.id), [back.id]);
      // ...and Undo reaches the written one.
      final r = await again.undo();
      expect(r.done, 1);
      expect(repo.records[move.id]!.type, 'expense');
      expect(repo.records[move.id]!.hasMarker, isFalse);
      expect(await again.changedIds(), isEmpty);
    });

    test('killed before a write: Undo finds it never changed, writes '
        'nothing and doesn\'t call it edited', () async {
      final f = await make([move]);
      final p = await f.preview();
      repo.killBeforeWrite = true;
      await expectLater(f.apply(p), throwsStateError);
      repo.killBeforeWrite = false;
      final again = await make([], restart: true);
      final r = await again.undo();
      expect([r.done, r.skipped], [0, 0]);
      expect(repo.writes, isEmpty);
      expect(r.log.any((l) => l.contains('was never changed')), isTrue);
      expect(await again.changedIds(), isEmpty);
    });

    test('a pending record can be retried safely; a written one keeps its '
        'first backup', () async {
      final f = await make([move, back]);
      final p = await f.preview();
      repo.killAfterWrite = true;
      await expectLater(f.apply(p), throwsStateError); // move written
      repo.killAfterWrite = false;
      final first = store.saved.firstWhere((b) => b['id'] == move.id);
      final again = await make([], restart: true);
      final r = await again.apply(await again.preview());
      expect(r.done, 1); // only the other one
      expect(repo.writes.where((w) => w == 'apply ${move.id}'), hasLength(1));
      // The original of the written record was never replaced.
      expect(store.saved.firstWhere((b) => b['id'] == move.id), first);
      expect(first['type'], 'expense');
    });

    test('the run log is saved and survives a restart', () async {
      final f = await make([move]);
      await f.apply(await f.preview());
      final again = await make([], restart: true);
      final log = await again.lastLog();
      expect(log.any((l) => l.contains('${move.id}: fixed')), isTrue);
      expect(log.any((l) => l.contains('Run finished: 1 fixed')), isTrue);
    });
  });

  group('Undo protects later edits (Gap B)', () {
    for (final (what, edit) in [
      ('fee', (FakeMoveRepo r) => r.userEdit(move.id, fee: 95)),
      ('SIM', (FakeMoveRepo r) => r.userEdit(move.id, simSlot: 0)),
      (
        'date',
        (FakeMoveRepo r) => r.userEdit(move.id, date: DateTime(2026, 9, 15)),
      ),
      (
        'note (only its save time changes here)',
        (FakeMoveRepo r) {
          r.userEdit(move.id);
        },
      ),
    ]) {
      test('an edit to the $what after the fix is left as it is', () async {
        final f = await make([move]);
        await f.apply(await f.preview());
        edit(repo);
        final before = repo.records[move.id]!;
        final r = await f.undo();
        expect([r.done, r.skipped], [0, 1]);
        final after = repo.records[move.id]!;
        expect(
          [after.type, after.fee, after.simSlot, after.date, after.updatedAt],
          [
            before.type,
            before.fee,
            before.simSlot,
            before.date,
            before.updatedAt,
          ],
        );
        expect(r.log.any((l) => l.contains('edited since the fix')), isTrue);
      });
    }
  });

  group('backup errors (Gap C)', () {
    test('a backup that cannot be saved stops before any write', () async {
      final f = await make([move]);
      store.failSaveBackup = true;
      final r = await f.apply(await f.preview());
      expect(r.error, contains('Nothing was changed'));
      expect(repo.writes, isEmpty);
      expect(store.changedIds, isEmpty);
    });

    testWidgets('a storage failure stops the spinner and says so', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 6000);
      addTearDown(tester.view.reset);
      final f = (await tester.runAsync(() => make([move])))!;
      store.failSaveChanged = true;
      await tester.pumpWidget(MaterialApp(home: MoveFixScreen(fix: f)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Back up and fix 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Back up and fix'));
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        find.textContaining('Something on this phone failed'),
        findsOneWidget,
      );
      expect(repo.writes, isEmpty);
    });
  });

  testWidgets('the screen shows each record, months and both kinds of '
      'change; looking writes nothing', (tester) async {
    tester.view.physicalSize = const Size(1080, 6000);
    addTearDown(tester.view.reset);
    final f = (await tester.runAsync(() => make([move, cashOut])))!;
    await tester.pumpWidget(MaterialApp(home: MoveFixScreen(fix: f)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('move-ready')), findsOneWidget);
    expect(
      find.textContaining('SIM 2 → SIM 1 M-Pesa · fee KSh 90.00'),
      findsOneWidget,
    );
    expect(find.textContaining('SIM 1 M-Pesa → Cash'), findsOneWidget);
    expect(find.textContaining('Past totals per account'), findsOneWidget);
    expect(find.text('Change to your account card balances:'), findsOneWidget);
    await tester.tap(find.text('Back up and fix 2'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('A backup is saved on this phone first'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(repo.writes, isEmpty);
    expect(store.saved, isEmpty);
  });

  test('a top-up from M-Pesa into the user’s own Equity becomes a move '
      'to the Equity account; Undo puts it back', () async {
    final topUp = rec(
      'UJV0000009',
      'expense',
      2000,
      category: 'bills',
      accountId: 'mpesa-sim1',
      simSlot: 0,
      account: 'mpesa',
    );
    final list = [
      ...MoneyAccount.starterSet(),
      const MoneyAccount(
        id: 'equity',
        name: 'Equity',
        kind: AccountKind.bank,
        provider: AccountProvider.equity,
      ),
    ];
    final acc = AccountStore(FakeAccountRepository(list));
    await Future<void>.delayed(Duration.zero);
    final f = await make(
      [topUp],
      accountStore: acc,
      messages: [
        sms(
          'UJV0000009 Confirmed. Ksh2,000.00 sent to Equity Paybill Account '
          'for account 1234567 on 31/10/26 at 10:46 AM New M-PESA balance is '
          'Ksh100.00. Transaction cost, Ksh0.00.',
          0,
        ),
        RawSms(
          sender: 'Equity Bank',
          body:
              'Confirmed. KES. 2,000.00 from PAT OWNER received via M-Pesa '
              'Ref. UJV0000009 on 31-10-2026 at 10:46. Thank you.',
          date: day,
          simSlot: 0,
        ),
      ],
    );
    final p = await f.preview();
    final c = p.changes.single;
    expect([c.kind, c.accountId, c.toAccountId, c.toAccount], [
      MoveKind.intoBank,
      'mpesa-sim1',
      'equity',
      'bank',
    ]);
    // Spending drops by the top-up; nothing else changes.
    final m = p.months.single;
    expect(m.before.expenses - m.after.expenses, 2000);
    await f.apply(p);
    final now = repo.records[topUp.id]!;
    expect([now.type, now.toAccountId, now.toAccount], [
      'transfer',
      'equity',
      'bank',
    ]);
    expect((await f.undo()).done, 1);
    expect(repo.records[topUp.id]!.type, 'expense');
  });

  test('a payment into someone else’s Equity account is left alone',
      () async {
    final other = rec('UJ00000003', 'expense', 400, accountId: 'mpesa-sim1');
    final f = await make(
      [other],
      messages: [
        sms(
          'UJ00000003 Confirmed. Ksh400.00 sent to Equity Paybill Account for '
          'account 7654321 on 30/9/26 at 10:00 AM New M-PESA balance is '
          'Ksh100.00. Transaction cost, Ksh0.00.',
          0,
        ),
        RawSms(
          sender: 'Equity Bank',
          body:
              'Dear PAT, Your transaction of KES. 400.00 has successfully been '
              'deposited to Equity Account in favor of JANE WANJIKU Ref. '
              'Number UJ00000003 on 30-09-2026 at 10:00. Thank you.',
          date: day,
          simSlot: 0,
        ),
      ],
    );
    expect((await f.preview()).changes, isEmpty);
  });
}
