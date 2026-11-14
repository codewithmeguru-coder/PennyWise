// Runs the app's real Firestore write paths (the repositories, the sign-in
// profile save, a repair tool's apply / undo and account deletion) against
// the LOCAL Firebase emulators, and checks the documents and the daily
// counters after each one. Never connects to production: the project is
// "demo-pennywise" and every call goes to the emulators.
//
//   firebase emulators:exec --config <config with auth 9099 + firestore 8097>
//     --only auth,firestore --project demo-pennywise
//     "flutter run -d windows -t tool/emulator_check.dart" (with STAGE=final in the environment)
//
// STAGE=final expects firestore.rules (claims required); STAGE=step1
// expects firestore.step1.rules (claims allowed, not required).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/widgets.dart';
import 'package:pennywise/accounts/account_repository.dart';
import 'package:pennywise/accounts/anchor_log.dart';
import 'package:pennywise/accounts/money_account.dart';
import 'package:pennywise/categorization/category_rule.dart';
import 'package:pennywise/categorization/category_rule_repository.dart';
import 'package:pennywise/data/avatar_repository.dart';
import 'package:pennywise/data/budget_repository.dart';
import 'package:pennywise/data/category_budget_repository.dart';
import 'package:pennywise/data/category_repository.dart';
import 'package:pennywise/data/data_exception.dart';
import 'package:pennywise/data/transaction_repository.dart';
import 'package:pennywise/data/write_limit.dart';
import 'package:pennywise/maintenance/internal_transfer_fix.dart';
import 'package:pennywise/maintenance/sim_backfill.dart';
import 'package:pennywise/models/budget_model.dart';
import 'package:pennywise/models/category_budget.dart';
import 'package:pennywise/models/custom_category.dart';
import 'package:pennywise/models/transaction_model.dart';
import 'package:pennywise/services/account_deletion.dart';
import 'package:pennywise/services/auth_service.dart';

final stage = Platform.environment['STAGE'] ?? 'final';
const project = 'demo-pennywise';
const host = '127.0.0.1';
const firestorePort = 8097;
const authPort = 9099;
final docs = 'http://$host:$firestorePort/v1/projects/$project/databases/(default)/documents';

int passed = 0, failed = 0;

/// Also written to RESULT_FILE (a desktop app's console output can be lost).
final _out = Platform.environment['RESULT_FILE'];
void say(String line) {
  // ignore: avoid_print
  print(line);
  final out = _out;
  if (out != null) {
    File(out).writeAsStringSync('$line\n', mode: FileMode.append);
  }
}

void check(String label, bool ok) {
  ok ? passed++ : failed++;
  say('${ok ? 'PASS' : 'FAIL'}  $label');
}

/// The [DataException] (with [message], if given) that [f] fails with, or
/// null if it succeeds or fails differently.
Future<DataException?> throwsData(Future<Object?> Function() f,
    [String? message]) async {
  try {
    await f();
    return null;
  } on DataException catch (e) {
    return (message == null || e.message == message) ? e : null;
  } catch (_) {
    return null;
  }
}

/// Whether [f] was refused. On Windows the cloud_firestore plugin reports a
/// transaction the server rejects only as an unhandled stream error, so
/// its Future never completes (Android reports it through the Future, see
/// TransactionStreamHandler); not completing counts as refused here, and
/// the checks that follow confirm nothing was written.
Future<bool> refused(Future<Object?> Function() f) async {
  try {
    await f().timeout(const Duration(seconds: 15));
    return false;
  } catch (_) {
    return true;
  }
}

int unhandled = 0;

/// The emulator's admin access ("Bearer owner"): reads and seeds without
/// the rules, for checking what the app wrote.
final _http = HttpClient();
Future<Map<String, dynamic>?> adminGet(String path) async {
  final req = await _http.getUrl(Uri.parse('$docs/$path'));
  req.headers.set('Authorization', 'Bearer owner');
  final res = await req.close();
  final body = await res.transform(utf8.decoder).join();
  return res.statusCode == 200 ? jsonDecode(body) as Map<String, dynamic> : null;
}

Future<void> adminCommit(List<Map<String, dynamic>> writes) async {
  final req = await _http.postUrl(Uri.parse('$docs:commit'));
  req.headers
    ..set('Authorization', 'Bearer owner')
    ..contentType = ContentType.json;
  req.write(jsonEncode({'writes': writes}));
  final res = await req.close();
  await res.drain<void>();
  if (res.statusCode != 200) throw StateError('admin commit ${res.statusCode}');
}

String _p(String uid, String path) => 'projects/$project/databases/(default)/documents/users/$uid/$path';

/// Sets counter [name] to [count], used today (or yesterday).
Future<void> seedCounter(String uid, String name, int count, {bool yesterday = false}) =>
    adminCommit([
      {
        'update': {
          'name': _p(uid, 'limits/$name'),
          'fields': {
            'count': {'integerValue': '$count'},
            'lastPath': {'stringValue': 'seed'},
            if (yesterday)
              'at': {
                'timestampValue': DateTime.now()
                    .toUtc()
                    .subtract(const Duration(days: 1))
                    .toIso8601String(),
              },
          },
        },
        if (!yesterday)
          'updateTransforms': [
            {'fieldPath': 'at', 'setToServerValue': 'REQUEST_TIME'},
          ],
      },
    ]);

Future<int> counter(String uid, String name) async {
  final d = await adminGet('users/$uid/limits/$name');
  return int.parse((d?['fields']?['count']?['integerValue'] as String?) ?? '0');
}

Future<Map<String, dynamic>?> counterFields(String uid, String name) async =>
    (await adminGet('users/$uid/limits/$name'))?['fields'] as Map<String, dynamic>?;

Future<bool> exists(String uid, String path) async => await adminGet('users/$uid/$path') != null;

Future<int> countDocs(String uid, String collection) async {
  final d = await adminGet('users/$uid/$collection?pageSize=300');
  return (d?['documents'] as List?)?.length ?? 0;
}

void main() => runZonedGuarded(_main, (e, s) {
      unhandled++;
      say('(unhandled platform error: $e)');
    });

Future<void> _main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: const FirebaseOptions(
      apiKey: 'demo-api-key',
      appId: '1:1234567890:web:0000000000000000',
      messagingSenderId: '1234567890',
      projectId: project,
    ),
  );
  final db = FirebaseFirestore.instance;
  db.useFirestoreEmulator(host, firestorePort);
  db.settings = const Settings(persistenceEnabled: false);
  await FirebaseAuth.instance.useAuthEmulator(host, authPort);
  final final_ = stage == 'final';
  say('Stage: $stage (${final_ ? 'firestore.rules' : 'firestore.step1.rules'})');

  try {
    await _run(db, final_);
  } catch (e, s) {
    check('unexpected error: $e\n$s', false);
  }
  say('\n$passed passed, $failed failed, $unhandled unhandled platform '
      'errors (stage $stage)');
  exit(failed == 0 ? 0 : 1);
}

Future<void> _run(FirebaseFirestore db, bool finalRules) async {
  final auth = FirebaseAuthService(firestore: db);
  final email = 'check${DateTime.now().millisecondsSinceEpoch}@example.com';
  const password = 'emulator-only-1';

  // ---- Sign-up: profile saved with one edit claim ---------------------------
  await auth.register(name: 'Check User', email: email, password: password);
  final uid = FirebaseAuth.instance.currentUser!.uid;
  await Future<void>.delayed(const Duration(seconds: 2));
  final claims =
      (await FirebaseAuth.instance.currentUser!.getIdTokenResult()).claims;
  if (claims?['email'] != null) {
    check('sign-up: profile saved', await adminGet('users/$uid') != null);
    check('sign-up: profile claimed 1 edit', await counter(uid, 'edits') == 1);
    await auth.signOut();
    await auth.signIn(email: email, password: password);
    await Future<void>.delayed(const Duration(seconds: 2));
    check('signing in again (nothing changed) claims nothing',
        await counter(uid, 'edits') == 1);
  } else {
    // The Windows desktop SDK's sign-in token has no email claim, and the
    // profile rule (unchanged since before Phase B) requires it, so the
    // profile can't be saved here; Android tokens carry it.
    say('SKIP  sign-up profile save: no email in this desktop token (the '
        'same writes with an email token are allowed in the rules tests)');
    check('sign-up: the refused profile save left no record and used no '
        'edit', await adminGet('users/$uid') == null &&
        await counter(uid, 'edits') == 0);
  }

  // ---- Transactions -----------------------------------------------------------
  final txs = FirestoreTransactionRepository(uid: uid, firestore: db);
  final lunch = TransactionModel(
    description: 'Lunch', amount: 450, type: TransactionType.expense,
    categoryId: 'food', date: DateTime(2026, 10, 30, 13),
  );
  final id = await txs.add(lunch);
  check('manual transaction created', await exists(uid, 'transactions/$id'));
  check('… claimed 1 new record (daily = 1)', await counter(uid, 'daily') == 1);
  check('… counter names it', (await counterFields(uid, 'daily'))?['lastPath']?['stringValue'] == 'transactions/$id');

  final sms = TransactionModel(
    description: 'NAIVAS', amount: 1200, type: TransactionType.expense,
    categoryId: 'shopping', date: DateTime(2026, 10, 30, 18),
    source: TransactionSource.mpesa, reference: 'TJK1ABCDEF', simSlot: 0,
    smsText: 'TJK1ABCDEF Confirmed. Ksh1,200.00 paid to NAIVAS.',
  );
  check('SMS transaction created', await txs.addDetected(sms, dedupeKey: 'mpesa_TJK1ABCDEF'));
  check('… claimed 1 (daily = 2)', await counter(uid, 'daily') == 2);
  check('the same SMS again: not created', !await txs.addDetected(sms, dedupeKey: 'mpesa_TJK1ABCDEF'));
  check('… and claimed nothing (daily = 2)', await counter(uid, 'daily') == 2);
  final sms2 = TransactionModel(
    description: 'JAVA HOUSE', amount: 800, type: TransactionType.expense,
    categoryId: 'food', date: DateTime(2026, 10, 31, 12),
    source: TransactionSource.mpesa, reference: 'TJK2ABCDEF', simSlot: 0,
    smsText: 'TJK2ABCDEF Confirmed. Ksh800.00 paid to JAVA HOUSE.',
  );
  await txs.addDetected(sms2, dedupeKey: 'mpesa_TJK2ABCDEF');

  final eEdit = await counter(uid, 'edits');
  await txs.update(TransactionModel(
    id: id, description: 'Lunch with team', amount: 450,
    type: TransactionType.expense, categoryId: 'food', date: lunch.date,
  ));
  check('transaction edited', (await adminGet('users/$uid/transactions/$id'))?['fields']?['description']?['stringValue'] == 'Lunch with team');
  check('… claimed 1 edit', await counter(uid, 'edits') == eEdit + 1);

  // ---- Failed writes leave no record and no used claim -------------------------
  final before = await countDocs(uid, 'transactions');
  final dBefore = await counter(uid, 'daily');
  final invalid = await refused(() => txs.add(TransactionModel(
    description: 'x' * 150, amount: 1, type: TransactionType.expense,
    categoryId: 'food', date: DateTime(2026, 10, 30),
  )));
  check('a transaction the rules refuse is refused', invalid);
  check('… no record was created', await countDocs(uid, 'transactions') == before);
  check('… and no claim was used', await counter(uid, 'daily') == dBefore);

  final eBefore = await counter(uid, 'edits');
  final badEdit = await refused(() => txs.update(TransactionModel(
    id: id, description: 'y' * 150, amount: 450,
    type: TransactionType.expense, categoryId: 'food', date: lunch.date,
  )));
  check('an edit the rules refuse is refused', badEdit);
  check('… the record is unchanged', (await adminGet('users/$uid/transactions/$id'))?['fields']?['description']?['stringValue'] == 'Lunch with team');
  check('… and no edit was used', await counter(uid, 'edits') == eBefore);

  // ---- At the limits -----------------------------------------------------------
  await seedCounter(uid, 'daily', WriteLimit.daily);
  final full = await throwsData(() => txs.add(lunch), WriteLimit.reachedMessage);
  check('at 1,500 today a new transaction is refused with the limit message', full != null);
  check('… nothing created', await countDocs(uid, 'transactions') == before);
  check('… counter still 1,500', await counter(uid, 'daily') == WriteLimit.daily);
  final fullSms = await throwsData(
      () => txs.addDetected(sms.copyWithReference('TJK9ABCDEF'), dedupeKey: 'mpesa_TJK9ABCDEF'),
      WriteLimit.reachedMessage);
  check('… an SMS transaction too (retried later, nothing lost)', fullSms != null && !await exists(uid, 'transactions/mpesa_TJK9ABCDEF'));
  // A full counter from yesterday: today's first new record is 1.
  await seedCounter(uid, 'daily', WriteLimit.daily, yesterday: true);
  await txs.add(lunch);
  check('a new UTC day: new records start again at 1', await counter(uid, 'daily') == 1);

  await seedCounter(uid, 'edits', WriteLimit.edits);
  final fullEdit = await throwsData(() => txs.update(TransactionModel(
    id: id, description: 'Edited at limit', amount: 450,
    type: TransactionType.expense, categoryId: 'food', date: lunch.date,
  )), WriteLimit.editsReachedMessage);
  check('at 3,000 today an edit is refused with the limit message', fullEdit != null);
  check('… the record is unchanged', (await adminGet('users/$uid/transactions/$id'))?['fields']?['description']?['stringValue'] == 'Lunch with team');
  check('… counter still 3,000', await counter(uid, 'edits') == WriteLimit.edits);
  await seedCounter(uid, 'edits', WriteLimit.edits, yesterday: true);
  await txs.update(TransactionModel(
    id: id, description: 'Lunch with team', amount: 450,
    type: TransactionType.expense, categoryId: 'food', date: lunch.date,
  ));
  check('a new UTC day: edits start again at 1', await counter(uid, 'edits') == 1);

  // ---- Writing without a claim (an old app, or a script) ----------------------
  Future<bool> allowed(Future<void> Function() f) async {
    try {
      await f();
      return true;
    } on FirebaseException catch (e) {
      return e.code != 'permission-denied' ? throw e : false;
    }
  }
  final col = db.collection('users').doc(uid).collection('transactions');
  final rawCreate = await allowed(() => col.doc('raw1').set({
        'amount': 5, 'type': 'expense', 'category': 'food', 'description': 'Tea',
        'date': Timestamp.fromDate(DateTime(2026, 10, 30)),
        'createdAt': FieldValue.serverTimestamp(), 'updatedAt': FieldValue.serverTimestamp(),
      }));
  final rawEdit = await allowed(() => col.doc(id).update({
        'description': 'Raw edit', 'updatedAt': FieldValue.serverTimestamp(),
      }));
  final rawAccount = await allowed(() => db.collection('users').doc(uid).collection('accounts').doc('raw-acct').set({
        'name': 'Raw', 'kind': 'cash', 'provider': 'none', 'active': true, 'order': 99,
        'createdAt': FieldValue.serverTimestamp(), 'updatedAt': FieldValue.serverTimestamp(),
      }));
  if (finalRules) {
    check('final: a new transaction without a claim is refused', !rawCreate);
    check('final: an edit without a claim is refused', !rawEdit);
    check('final: a new account without a claim is refused', !rawAccount);
  } else {
    check('step 1: an old app\'s new transaction (no claim) still works', rawCreate);
    check('step 1: an old app\'s edit (no claim) still works', rawEdit);
    check('step 1: an old app\'s new account (no claim) still works', rawAccount);
  }

  // ---- Accounts ------------------------------------------------------------------
  final accounts = FirestoreAccountRepository(uid: uid, firestore: db);
  final starter = MoneyAccount.starterSet();
  final d0 = await counter(uid, 'daily');
  await accounts.createMissing(starter);
  check('starter accounts created (${starter.length})', (await Future.wait([for (final a in starter) exists(uid, 'accounts/${a.id}')])).every((x) => x));
  check('… one claim each (daily +${starter.length})', await counter(uid, 'daily') == d0 + starter.length);
  await accounts.createMissing(starter);
  check('set up again: nothing new, nothing claimed', await counter(uid, 'daily') == d0 + starter.length);

  final e0 = await counter(uid, 'edits');
  final sim1 = starter.first;
  await accounts.save(sim1.copyWith(name: 'Safaricom line'));
  check('account edited', (await adminGet('users/$uid/accounts/${sim1.id}'))?['fields']?['name']?['stringValue'] == 'Safaricom line');
  check('… claimed 1 edit', await counter(uid, 'edits') == e0 + 1);
  final d1 = await counter(uid, 'daily');
  await accounts.save(const MoneyAccount(id: 'equity-bank', name: 'Equity', kind: AccountKind.bank, provider: AccountProvider.equity, order: 50));
  check('new account added by hand', await exists(uid, 'accounts/equity-bank'));
  check('… claimed 1 new record', await counter(uid, 'daily') == d1 + 1);

  final keeper = AnchorKeeperHarness(accounts);
  final withBalance = sim1.copyWith(name: 'Safaricom line', openingBalance: 2500, openingDate: DateTime(2026, 10, 1));
  final change = keeper.changeFor(sim1.copyWith(name: 'Safaricom line'), withBalance);
  final e1 = await counter(uid, 'edits'), d2 = await counter(uid, 'daily');
  check('starting balance saved with its history record', await accounts.saveWithAnchor(withBalance, change));
  check('… record exists', await exists(uid, 'balanceAnchors/${change.id}'));
  check('… 1 edit (account) + 1 new record (history)', await counter(uid, 'edits') == e1 + 1 && await counter(uid, 'daily') == d2 + 1);
  check('saving the same balance again writes nothing', !await accounts.saveWithAnchor(withBalance, keeper.changeFor(withBalance, withBalance)));
  check('… and claims nothing', await counter(uid, 'edits') == e1 + 1 && await counter(uid, 'daily') == d2 + 1);
  check('Undo restores it', await accounts.undoAnchor(sim1.copyWith(name: 'Safaricom line'), change));
  check('… 1 edit, no new record', await counter(uid, 'edits') == e1 + 2 && await counter(uid, 'daily') == d2 + 1);

  // ---- Budgets, category limits, photo ------------------------------------------
  final e2 = await counter(uid, 'edits');
  final budgets = FirestoreBudgetRepository(uid: uid, firestore: db);
  await budgets.save(BudgetModel(month: DateTime(2026, 11), limit: 30000));
  await budgets.save(BudgetModel(month: DateTime(2026, 11), limit: 32000));
  final limit = (await adminGet('users/$uid/budgets/2026-11'))?['fields']?['limit'];
  check('budget created and changed', (limit?['doubleValue'] ?? num.tryParse('${limit?['integerValue']}')) == 32000);
  final limits = FirestoreCategoryBudgetRepository(uid: uid, firestore: db);
  await limits.save(CategoryBudget(month: DateTime(2026, 11), categoryId: 'food', limit: 8000));
  check('category limit saved', await exists(uid, 'categoryBudgets/2026-11_food'));
  final avatar = FirestoreAvatarRepository(uid: uid, firestore: db);
  await avatar.save(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, 0x4A, 0x46]));
  check('profile photo saved', await exists(uid, 'private/avatar'));
  check('… 4 saves, 4 edits', await counter(uid, 'edits') == e2 + 4);

  // ---- Learned and custom categories ------------------------------------------------
  final rules = FirestoreCategoryRuleRepository(uid: uid, firestore: db);
  final e3 = await counter(uid, 'edits'), d3 = await counter(uid, 'daily');
  const rule = CategoryRule(key: 'OUT:NAIVAS', categoryId: 'shopping', type: TransactionType.expense);
  await rules.remember(rule);
  check('learned category created: 1 new record', await exists(uid, 'categoryRules/OUT:NAIVAS') && await counter(uid, 'daily') == d3 + 1);
  await rules.remember(rule);
  check('learned again: 1 edit, count 2', await counter(uid, 'edits') == e3 + 1 && (await adminGet('users/$uid/categoryRules/OUT:NAIVAS'))?['fields']?['count']?['integerValue'] == '2');
  final cats = FirestoreCategoryRepository(uid: uid, firestore: db);
  const pets = CustomCategory(id: 'c_petsabcd', name: 'Pets', type: TransactionType.expense);
  await cats.create(pets);
  check('custom category created: 1 new record', await exists(uid, 'categories/c_petsabcd') && await counter(uid, 'daily') == d3 + 2);
  await cats.update(pets.copyWith(name: 'Pet care'));
  check('custom category renamed: 1 edit', await counter(uid, 'edits') == e3 + 2);

  // ---- Repair tools ------------------------------------------------------------------
  final move = FirestoreMoveFixRepository(uid: uid, firestore: db);
  final record = (await move.smsRecords()).firstWhere((r) => r.id == 'mpesa_TJK1ABCDEF');
  final moveChange = MoveChange(record: record, kind: MoveKind.cashWithdrawal, fromSim: 0, accountId: sim1.id, toAccountId: 'cash');
  final e4 = await counter(uid, 'edits');
  check('internal transfer fix: applied', await move.apply(moveChange));
  check('… now a transfer, 1 edit', (await adminGet('users/$uid/transactions/mpesa_TJK1ABCDEF'))?['fields']?['type']?['stringValue'] == 'transfer' && await counter(uid, 'edits') == e4 + 1);
  check('internal transfer fix: undone', await move.undo(record, moveChange) == UndoOutcome.undone);
  check('… back to an expense, 1 edit', (await adminGet('users/$uid/transactions/mpesa_TJK1ABCDEF'))?['fields']?['type']?['stringValue'] == 'expense' && await counter(uid, 'edits') == e4 + 2);

  final backfill = FirestoreSimBackfillRepository(uid: uid, firestore: db);
  final bRecord = (await backfill.smsRecords()).firstWhere((r) => r.id == 'mpesa_TJK2ABCDEF');
  check('SIM fill-in: applied', await backfill.apply(BackfillChange(bRecord, 0, sim1.id, SimEvidence.stored)));
  check('… account set, 1 edit', (await adminGet('users/$uid/transactions/mpesa_TJK2ABCDEF'))?['fields']?['accountId']?['stringValue'] == sim1.id && await counter(uid, 'edits') == e4 + 3);
  check('SIM fill-in: undone', await backfill.undo('mpesa_TJK2ABCDEF', accountId: sim1.id, removeSim: false, type: 'expense', category: 'food'));
  check('… account removed, 1 edit', (await adminGet('users/$uid/transactions/mpesa_TJK2ABCDEF'))?['fields']?['accountId'] == null && await counter(uid, 'edits') == e4 + 4);
  await seedCounter(uid, 'edits', WriteLimit.edits);
  final fresh = (await backfill.smsRecords()).firstWhere((r) => r.id == 'mpesa_TJK2ABCDEF');
  final repairFull = await throwsData(() => backfill.apply(BackfillChange(fresh, 0, sim1.id, SimEvidence.stored)), WriteLimit.editsReachedMessage);
  check('repair at the edit limit: stops with the limit message, record untouched', repairFull != null && (await adminGet('users/$uid/transactions/mpesa_TJK2ABCDEF'))?['fields']?['accountId'] == null);

  // ---- Account deletion: the cleanup claims nothing -------------------------------------
  final editsBefore = await counter(uid, 'edits'), dailyBefore = await counter(uid, 'daily');
  await AccountDeletion(data: FirestoreUserDataStore(uid: uid, firestore: db), auth: auth, clearLocal: () async {}).run();
  final left = <String>[
    for (final c in AccountDeletion.collections)
      if (await countDocs(uid, c) > 0) c,
  ];
  check('deletion: every collection is empty', left.isEmpty);
  check('deletion: photo and profile gone', !await exists(uid, 'private/avatar') && await adminGet('users/$uid') == null);
  check('deletion: request removed', !await exists(uid, 'deletionRequest/current'));
  check('deletion: sign-in deleted', FirebaseAuth.instance.currentUser == null);
  for (final name in ['daily', 'edits']) {
    final f = await counterFields(uid, name);
    check('deletion: today\'s $name counter stays with only count, time and an empty path', f != null && f.keys.toSet().containsAll({'count', 'at', 'lastPath'}) && f.length == 3 && f['lastPath']?['stringValue'] == '');
  }
  check('deletion: the cleanup claimed no edit and no new record', await counter(uid, 'edits') == editsBefore && await counter(uid, 'daily') == dailyBefore);
}

/// Builds history records the way [AnchorKeeper.change] does.
class AnchorKeeperHarness {
  AnchorKeeperHarness(this._accounts);
  final AccountRepository _accounts;
  int _n = 0;
  AnchorChange changeFor(MoneyAccount current, MoneyAccount updated) {
    _n++;
    final now = DateTime.now();
    assert(_accounts is FirestoreAccountRepository);
    return AnchorChange(
      id: '${updated.id}_${now.microsecondsSinceEpoch}$_n',
      accountId: updated.id,
      at: now,
      reason: 'Edited',
      before: current.openingBalance,
      beforeDate: current.openingDate,
      after: updated.openingBalance,
      afterDate: updated.openingDate,
    );
  }
}

extension on TransactionModel {
  TransactionModel copyWithReference(String reference) => TransactionModel(
        description: description, amount: amount, type: type,
        categoryId: categoryId, date: date, source: source,
        reference: reference, simSlot: simSlot, smsText: smsText,
      );
}
