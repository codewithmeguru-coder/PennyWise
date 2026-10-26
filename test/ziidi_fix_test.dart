import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/accounts/account_repository.dart';
import 'package:pennywise/accounts/money_account.dart';
import 'package:pennywise/data/data_exception.dart';
import 'package:pennywise/maintenance/ziidi_fix.dart';
import 'package:pennywise/maintenance/ziidi_matcher.dart';
import 'package:pennywise/models/ledger.dart';
import 'package:pennywise/models/transaction_model.dart';
import 'package:pennywise/sms/sms_gateway.dart';

import 'fake_accounts.dart';
import 'fake_sms.dart';

// "Fix old Ziidi records", in memory only: fake records, a fake inbox, no
// Firestore and no phone.

final created = DateTime(2026, 10, 6, 10);
DateTime day(int d) => DateTime(2026, 9, d, 9);

String sentToZiidi(String code, String amount) =>
    '$code Confirmed. Ksh$amount sent to ZIIDI on 6/9/26 at 9:00 AM New '
    'M-PESA balance is Ksh100.00. Transaction cost, Ksh0.00.';
String fromZiidi(String code, String amount) =>
    '$code Confirmed.You have received Ksh$amount from ZIIDI on 7/9/26 at '
    '9:00 AM New M-PESA balance is Ksh600.00.';
String personWithAdvert(String code) =>
    '$code Confirmed.You have received Ksh200.00 from JOHN DOE 0712345678 on '
    '7/9/26 at 9:00 AM New M-PESA balance is Ksh800.00. Save with ZIIDI on '
    'M-PESA and earn daily.';

ZiidiRecord rec(String code, String type, String category, double amount,
        String sms,
        {DateTime? updated, int? sim, ({String type, String category})? marker}) =>
    ZiidiRecord(
      id: 'mpesa_$code',
      type: type,
      category: category,
      amount: amount,
      date: day(6),
      source: 'mpesa',
      reference: code,
      smsText: sms,
      createdAt: created,
      updatedAt: updated ?? created,
      simSlot: sim,
      marker: marker,
    );

/// Records kept like Firestore keeps them, with the same apply / undo checks
/// as the real repository.
class FakeZiidiRepo implements ZiidiFixRepository {
  FakeZiidiRepo(List<ZiidiRecord> records)
      : records = {for (final r in records) r.id: r};

  final Map<String, ZiidiRecord> records;
  final applied = <String>[];
  String? failOn;
  var reads = 0;

  @override
  Future<List<ZiidiRecord>> smsRecords() async {
    reads++;
    return records.values.toList();
  }

  @override
  Future<bool> apply(ZiidiChange c) async {
    if (c.record.id == failOn) throw const DataException('No connection.');
    final now = records[c.record.id];
    if (now == null ||
        now.marker != null ||
        now.type != c.record.type ||
        now.category != c.record.category ||
        now.updatedAt != c.record.updatedAt) {
      return false;
    }
    applied.add(now.id);
    records[now.id] = ZiidiRecord(
      id: now.id,
      type: c.check.newType!,
      category: c.check.newCategory!,
      amount: now.amount,
      date: now.date,
      source: now.source,
      reference: now.reference,
      smsText: now.smsText,
      createdAt: now.createdAt,
      updatedAt: created.add(const Duration(days: 30)),
      marker: (type: now.type, category: now.category),
      simSlot: c.simSlot ?? now.simSlot,
      accountId: c.accountId ?? now.accountId,
      toAccountId: c.toAccountId ?? now.toAccountId,
    );
    return true;
  }

  @override
  Future<bool> undo(String id, {required bool removeSim}) async {
    final now = records[id];
    final m = now?.marker;
    if (now == null || m == null) return false;
    final expected = ZiidiMatcher.check(ZiidiRecord(
      id: now.id,
      type: m.type,
      category: m.category,
      amount: now.amount,
      date: now.date,
      source: now.source,
      reference: now.reference,
      smsText: now.smsText,
      createdAt: now.createdAt,
      updatedAt: now.createdAt,
    ).stored);
    if (now.type != expected.newType || now.category != expected.newCategory) {
      return false;
    }
    records[id] = ZiidiRecord(
      id: now.id,
      type: m.type,
      category: m.category,
      amount: now.amount,
      date: now.date,
      source: now.source,
      reference: now.reference,
      smsText: now.smsText,
      createdAt: now.createdAt,
      updatedAt: created.add(const Duration(days: 31)),
      simSlot: removeSim ? null : now.simSlot,
      accountId: removeSim ? null : now.accountId,
      toAccountId: removeSim ? null : now.toAccountId,
    );
    return true;
  }

  /// The records as transactions, for totals.
  List<TransactionModel> asTransactions() => [
        for (final r in records.values)
          TransactionModel(
            id: r.id,
            description: 'x',
            amount: r.amount,
            type: TransactionType.fromWire(r.type)!,
            categoryId: r.category,
            date: r.date,
            source: TransactionSource.mpesa,
            account: Account.mpesa,
          ),
      ];
}

class MemoryZiidiStore implements ZiidiFixStore {
  List<Map<String, Object?>> saved = [];
  Map<String, bool> changedIds = {};
  bool corruptReadBack = false;

  @override
  Future<List<Map<String, Object?>>> backup() async => corruptReadBack
      ? const []
      : [for (final r in saved) Map.of(r)];

  @override
  Future<void> saveBackup(List<Map<String, Object?>> records) async =>
      saved = [for (final r in records) Map.of(r)];

  @override
  Future<Map<String, bool>> changed() async => Map.of(changedIds);

  @override
  Future<void> saveChanged(Map<String, bool> c) async => changedIds = Map.of(c);
}

late FakeZiidiRepo repo;
late MemoryZiidiStore store;
late FakeSmsGateway gateway;

Future<ZiidiFixer> setUpFixer(List<ZiidiRecord> records,
    {List<RawSms> inbox = const [], bool withAccounts = true}) async {
  repo = FakeZiidiRepo(records);
  store = MemoryZiidiStore();
  gateway = FakeSmsGateway(permissionGranted: true)..inbox.addAll(inbox);
  AccountStore? accounts;
  if (withAccounts) {
    accounts = AccountStore(FakeAccountRepository(MoneyAccount.starterSet()));
    await Future<void>.delayed(Duration.zero);
  }
  return ZiidiFixer(
    repository: repo,
    store: store,
    gateway: gateway,
    accounts: () => accounts,
  );
}

final save1 = rec('UJZAB1CD01', 'expense', 'uncategorized', 1, sentToZiidi('UJZAB1CD01', '1.00'));
final save2 = rec('UJZAB1CD02', 'expense', 'uncategorized', 500, sentToZiidi('UJZAB1CD02', '500.00'));
final out1 = rec('UJZAB1CD03', 'income', 'uncategorized_income', 300, fromZiidi('UJZAB1CD03', '300.00'));
final advert = rec('UJZAB1CD04', 'income', 'money_received', 200, personWithAdvert('UJZAB1CD04'));
final edited = rec('UJZAB1CD05', 'expense', 'food', 50, sentToZiidi('UJZAB1CD05', '50.00'),
    updated: created.add(const Duration(days: 1)));
final fixedAlready = rec('UJZAB1CD06', 'savings_contribution', 'savings', 20,
    sentToZiidi('UJZAB1CD06', '20.00'),
    marker: (type: 'expense', category: 'uncategorized'));
final all = [save1, save2, out1, advert, edited, fixedAlready];

RawSms inboxSms(String body, int? slot) =>
    RawSms(sender: 'MPESA', body: body, date: day(6), simSlot: slot);

void main() {
  test('preview reads only and finds exactly the Ziidi moves', () async {
    final fixer = await setUpFixer(all);
    final p = await fixer.preview();
    expect(repo.applied, isEmpty);
    expect(store.saved, isEmpty);
    expect(store.changedIds, isEmpty);
    expect(p.changes.map((c) => c.record.id),
        unorderedEquals([save1.id, save2.id, out1.id]));
    expect(p.contributions, 2);
    expect(p.withdrawals, 1);
    expect(p.contributed, 501);
    expect(p.withdrawn, 300);
    // The advert isn't Ziidi; the edited and already-fixed ones are left.
    expect(p.changes.any((c) => c.record.id == advert.id), isFalse);
    expect(p.skipped['Edited by you after import'], 1);
    expect(p.skipped['Already fixed'], 1);
  });

  test('SIM only from the phone\'s own records; otherwise unknown',
      () async {
    final fixer = await setUpFixer(all, inbox: [
      inboxSms(save2.smsText!, 1), // SIM 2
      inboxSms(out1.smsText!, null), // SIM not recorded
    ]);
    final p = await fixer.preview();
    ZiidiChange of(ZiidiRecord r) =>
        p.changes.firstWhere((c) => c.record.id == r.id);
    expect(of(save2).simSlot, 1);
    expect(of(save2).accountId, 'mpesa-sim2');
    expect(of(save2).toAccountId, 'ziidi-sim2');
    expect(of(out1).simSlot, isNull);
    expect(of(save1).simSlot, isNull); // not in the inbox at all
    expect(of(save1).accountId, isNull);
  });

  test('a code seen on both SIMs gives no SIM', () async {
    final fixer = await setUpFixer([save2], inbox: [
      inboxSms(save2.smsText!, 0),
      inboxSms(save2.smsText!, 1),
    ]);
    expect((await fixer.preview()).changes.single.simSlot, isNull);
  });

  test('fix: backup first, then only type, category and marker change',
      () async {
    final fixer = await setUpFixer(all, inbox: [inboxSms(save2.smsText!, 1)]);
    final r = await fixer.fix(await fixer.preview());
    expect(r.done, 3);
    expect(r.error, isNull);
    // Backup of every changed record, with its original values.
    expect(store.saved.map((b) => b['id']),
        unorderedEquals([save1.id, save2.id, out1.id]));
    expect(store.saved.firstWhere((b) => b['id'] == out1.id)['type'], 'income');

    for (final before in [save1, save2, out1]) {
      final after = repo.records[before.id]!;
      expect(after.id, before.id);
      expect(after.amount, before.amount);
      expect(after.date, before.date);
      expect(after.reference, before.reference);
      expect(after.smsText, before.smsText);
      expect(after.marker, (type: before.type, category: before.category));
    }
    expect(repo.records[save1.id]!.type, 'savings_contribution');
    expect(repo.records[save1.id]!.category, 'savings');
    expect(repo.records[out1.id]!.type, 'savings_withdrawal');
    expect(repo.records[save1.id]!.simSlot, isNull); // unknown stays unknown
    expect(repo.records[save2.id]!.simSlot, 1);
    // Untouched.
    expect(repo.records[advert.id], same(advert));
    expect(repo.records[edited.id], same(edited));
  });

  test('totals: out of spending and income, into savings', () async {
    final fixer = await setUpFixer([save1, save2, out1]);
    final before = Ledger.of(repo.asTransactions());
    expect(before.spending, 501);
    expect(before.income, 300);
    await fixer.fix(await fixer.preview());
    final after = Ledger.of(repo.asTransactions());
    expect(after.spending, 0);
    expect(after.income, 0);
    expect(after.savingsBalance, 501 - 300);
    expect(after.available, before.available); // money didn't appear or vanish
  });

  test('a backup that can\'t be checked stops before any change', () async {
    final fixer = await setUpFixer(all);
    store.corruptReadBack = true;
    final r = await fixer.fix(await fixer.preview());
    expect(r.error, contains('Nothing was changed'));
    expect(repo.applied, isEmpty);
  });

  test('a record edited after the preview is left alone', () async {
    final fixer = await setUpFixer([save1, save2]);
    final p = await fixer.preview();
    repo.records[save2.id] = rec('UJZAB1CD02', 'expense', 'food', 500,
        save2.smsText!, updated: created.add(const Duration(days: 2)));
    final r = await fixer.fix(p);
    expect((r.done, r.skipped), (1, 1));
    expect(repo.records[save2.id]!.category, 'food');
  });

  test('no duplicates: a repeated fix changes nothing more; taps while '
      'running are ignored', () async {
    final fixer = await setUpFixer(all);
    final p = await fixer.preview();
    final first = fixer.fix(p);
    final second = await fixer.fix(p);
    expect(second.error, isNotNull);
    await first;
    final again = await fixer.fix(p);
    expect(again.done, 0);
    expect(repo.applied, hasLength(3));
  });

  test('a failure part-way keeps an exact list of what changed', () async {
    final fixer = await setUpFixer([save1, save2, out1]);
    repo.failOn = save2.id;
    final r = await fixer.fix(await fixer.preview());
    expect(r.error, 'No connection.');
    expect(store.changedIds.keys, [save1.id]);
  });

  test('Undo restores exactly the changed records; edited ones and others '
      'stay', () async {
    final fixer = await setUpFixer(all, inbox: [inboxSms(save2.smsText!, 1)]);
    await fixer.fix(await fixer.preview());
    // The user re-categorises one fixed record afterwards.
    final f = repo.records[out1.id]!;
    repo.records[out1.id] = ZiidiRecord(
      id: f.id, type: f.type, category: 'gift', amount: f.amount,
      date: f.date, source: f.source, reference: f.reference,
      smsText: f.smsText, createdAt: f.createdAt, updatedAt: f.updatedAt,
      marker: f.marker);

    final r = await fixer.undo();
    expect((r.done, r.skipped), (2, 1));
    for (final original in [save1, save2]) {
      final now = repo.records[original.id]!;
      expect(now.type, original.type);
      expect(now.category, original.category);
      expect(now.marker, isNull);
      expect(now.simSlot, isNull); // the SIM the fix added is removed
      expect(now.accountId, isNull);
      expect(now.amount, original.amount);
    }
    expect(repo.records[out1.id]!.category, 'gift'); // user's edit kept
    expect(repo.records[advert.id], same(advert));
    expect(store.changedIds, isEmpty);
    expect((await fixer.undo()).done, 0); // nothing twice
  });

  test('after its own Undo the fix can run again; records the user changed '
      'since are still left alone', () async {
    final fixer = await setUpFixer([save1, save2, out1]);
    await fixer.fix(await fixer.preview());
    await fixer.undo();
    // Undo stamped updatedAt, so the matcher alone would call them edited.
    expect(repo.records[save1.id]!.updatedAt, isNot(save1.updatedAt));
    // The user re-categorises one after the Undo.
    final r2 = repo.records[save2.id]!;
    repo.records[save2.id] = ZiidiRecord(
      id: r2.id, type: r2.type, category: 'food', amount: r2.amount,
      date: r2.date, source: r2.source, reference: r2.reference,
      smsText: r2.smsText, createdAt: r2.createdAt,
      updatedAt: r2.updatedAt!.add(const Duration(minutes: 1)));

    final again = await fixer.preview();
    expect(again.changes.map((c) => c.record.id),
        unorderedEquals([save1.id, out1.id]));
    final r = await fixer.fix(again);
    expect(r.done, 2);
    expect(repo.records[save1.id]!.type, 'savings_contribution');
    expect(repo.records[save1.id]!.amount, save1.amount);
    expect(repo.records[save1.id]!.marker,
        (type: 'expense', category: 'uncategorized'));
    expect(repo.records[save2.id]!.category, 'food'); // user's change kept
  });

  test('a record edited by the user that this fix never backed up stays '
      'left alone', () async {
    final fixer = await setUpFixer([edited]);
    final p = await fixer.preview();
    expect(p.changes, isEmpty);
    expect(p.skipped['Edited by you after import'], 1);
  });

  test('the backup is plain JSON with ids and original fields', () async {
    final fixer = await setUpFixer([save1]);
    await fixer.fix(await fixer.preview());
    final b = store.saved.single;
    expect(jsonDecode(jsonEncode(b)), b);
    expect(b, containsPair('type', 'expense'));
    expect(b, containsPair('category', 'uncategorized'));
    expect(b, containsPair('reference', 'UJZAB1CD01'));
  });
}
