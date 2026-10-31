import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../accounts/account_repository.dart';
import '../accounts/money_account.dart';
import '../data/data_exception.dart';
import '../models/ledger.dart';
import '../models/monthly_summary.dart';
import '../models/transaction_model.dart';
import '../sms/sms_gateway.dart';
import '../sms/sms_parser.dart';
import '../sms/sms_transaction.dart';
import 'account_assignment.dart';
import 'ziidi_fix.dart';

/// One stored SMS record as this fix sees it: everything it may change and
/// must be able to put back exactly.
class MoveRecord {
  const MoveRecord({
    required this.id,
    required this.type,
    required this.category,
    required this.amount,
    required this.date,
    this.reference,
    this.account,
    this.toAccount,
    this.accountId,
    this.toAccountId,
    this.simSlot,
    this.fee,
    this.hasMarker = false,
    this.markerAt,
    this.updatedAt,
  });

  final String id;
  final String type;
  final String category;
  final double amount;
  final DateTime date;
  final String? reference;

  /// Generic account wire names ("mpesa", "cash") and account ids.
  final String? account, toAccount, accountId, toAccountId;
  final int? simSlot;
  final double? fee;

  /// Carries an undo marker (`reclassifiedFrom`) from a fix, stamped at
  /// [markerAt]. The rules make that equal `updatedAt` when the fix writes,
  /// so any later edit leaves `updatedAt` newer.
  final bool hasMarker;
  final DateTime? markerAt;
  final DateTime? updatedAt;

  /// The original, for the backup and for Undo.
  Map<String, Object?> toJson() => {
    'id': id,
    'type': type,
    'category': category,
    'amount': amount,
    'date': date.toIso8601String(),
    'reference': reference,
    'account': account,
    'toAccount': toAccount,
    'accountId': accountId,
    'toAccountId': toAccountId,
    'simSlot': simSlot,
    'fee': fee,
  };
}

/// What Undo found for one record.
enum UndoOutcome {
  /// It still held exactly what the fix set: put back.
  undone,

  /// The fix never reached it (e.g. the app stopped before its write): it
  /// is already as it was, so nothing to put back.
  notApplied,

  /// Edited (or deleted) since the fix: left as it is.
  editedSince,
}

/// What this fix keeps on this phone, per profile: the verified backup of
/// the originals, the Undo list (`false` = write about to be attempted,
/// `true` = written) and the run log.
abstract class MoveFixStore implements ZiidiFixStore {
  Future<List<String>> log();
  Future<void> saveLog(List<String> lines);
}

class SharedPrefsMoveFixStore implements MoveFixStore {
  SharedPrefsMoveFixStore({required String uid}) : _prefix = 'move_fix_${uid}_';

  final String _prefix;

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  @override
  Future<List<Map<String, Object?>>> backup() async {
    final raw = (await _prefs).getString('${_prefix}backup') ?? '[]';
    return [
      for (final r in jsonDecode(raw) as List)
        (r as Map).cast<String, Object?>(),
    ];
  }

  @override
  Future<void> saveBackup(List<Map<String, Object?>> records) async {
    if (!await (await _prefs).setString(
      '${_prefix}backup',
      jsonEncode(records),
    )) {
      throw StateError('backup not saved');
    }
  }

  @override
  Future<Map<String, bool>> changed() async {
    final raw = (await _prefs).getString('${_prefix}changed') ?? '{}';
    return (jsonDecode(raw) as Map).cast<String, bool>();
  }

  @override
  Future<void> saveChanged(Map<String, bool> changed) async {
    if (!await (await _prefs).setString(
      '${_prefix}changed',
      jsonEncode(changed),
    )) {
      throw StateError('Undo list not saved');
    }
  }

  @override
  Future<List<String>> log() async =>
      (await _prefs).getStringList('${_prefix}log') ?? const [];

  @override
  Future<void> saveLog(List<String> lines) async =>
      (await _prefs).setStringList('${_prefix}log', lines);
}

/// What a move is, by the phone's own messages.
enum MoveKind {
  /// Sent from one of the user's SIMs and received on the other.
  betweenSims,

  /// Withdrawn as cash at an agent.
  cashWithdrawal,

  /// Paid from M-Pesa into the user's own Equity account: Equity's "received
  /// via M-Pesa" message carries the same code.
  intoBank,
}

/// The correction for one record: a transfer between the user's own
/// accounts, plus the provider's charge where it wasn't counted yet.
class MoveChange {
  const MoveChange({
    required this.record,
    required this.kind,
    required this.fromSim,
    required this.accountId,
    required this.toAccountId,
    this.toSim,
    this.addFee,
  });

  final MoveRecord record;
  final MoveKind kind;

  /// 0 = SIM 1. [toSim] only for [MoveKind.betweenSims].
  final int fromSim;
  final int? toSim;
  final String accountId, toAccountId;

  /// The charge the SMS states, set only when the record has no fee.
  final double? addFee;

  /// The generic account on the other side: Cash for a withdrawal. Two
  /// M-Pesa lines share "mpesa", so a SIM-to-SIM move has none (only the
  /// account ids tell them apart), as the transaction form saves it.
  String? get toAccount => switch (kind) {
    MoveKind.cashWithdrawal => Account.cash.wireName,
    MoveKind.intoBank => Account.bank.wireName,
    MoveKind.betweenSims => null,
  };
}

/// Totals for one month, before and after.
class MoveMonth {
  const MoveMonth(this.month, this.before, this.after);
  final DateTime month;
  final MonthlySummary before, after;
}

/// The preview: what would change, what is held back and why, and the
/// effect on months, account history and card balances.
class MovePreview {
  const MovePreview({
    this.changes = const [],
    this.blocked = const [],
    this.skipped = const {},
    this.months = const [],
    this.history = const {},
    this.cards = const {},
  });

  final List<MoveChange> changes;

  /// Cash withdrawals held back until Cash has a starting balance dated
  /// after them (otherwise old cash would show as held today).
  final List<MoveChange> blocked;
  final Map<String, int> skipped;
  final List<MoveMonth> months;

  /// Past income minus spending per account (not a balance change).
  final Map<MoneyAccount, double> history;

  /// Change in the balance each card shows.
  final Map<MoneyAccount, double> cards;

  int count(MoveKind k) => changes.where((c) => c.kind == k).length;
  double get feesAdded => changes.fold(0, (s, c) => s + (c.addFee ?? 0));
}

/// What a run or Undo did, record by record.
class MoveRunResult {
  const MoveRunResult({
    this.done = 0,
    this.skipped = 0,
    this.error,
    this.log = const [],
  });
  final int done, skipped;
  final String? error;

  /// One line per record: "applied", "left alone: changed since" ...
  final List<String> log;
}

/// Reads and writes the records this fix touches.
abstract class MoveFixRepository {
  /// Every stored transaction that came from an M-Pesa SMS.
  Future<List<MoveRecord>> smsRecords();

  /// Applies [change] only if the record is exactly as previewed;
  /// otherwise writes nothing and returns false.
  Future<bool> apply(MoveChange change);

  /// Puts [original] back (type, category, accounts, SIM, fee) and removes
  /// the marker, only while the record still holds exactly what the fix set
  /// ([change]) and wasn't edited since. A record with no marker was never
  /// changed by the fix.
  Future<UndoOutcome> undo(MoveRecord original, MoveChange change);
}

class FirestoreMoveFixRepository implements MoveFixRepository {
  FirestoreMoveFixRepository({required this._uid, this._firestore});

  final String _uid;
  final FirebaseFirestore? _firestore;

  // Resolved on first use, so creating the fix touches nothing.
  late final CollectionReference<Map<String, dynamic>> _collection =
      (_firestore ?? FirebaseFirestore.instance)
          .collection('users')
          .doc(_uid)
          .collection('transactions');

  static MoveRecord? recordFrom(DocumentSnapshot<Map<String, dynamic>> d) {
    final data = d.data();
    if (data == null) return null;
    return MoveRecord(
      id: d.id,
      type: data['type'] as String? ?? '',
      category: data['category'] as String? ?? '',
      amount: (data['amount'] as num?)?.toDouble() ?? 0,
      date: (data['date'] as Timestamp?)?.toDate() ?? DateTime(1970),
      reference: data['reference'] as String?,
      account: data['account'] as String?,
      toAccount: data['toAccount'] as String?,
      accountId: data['accountId'] as String?,
      toAccountId: data['toAccountId'] as String?,
      simSlot: data['simSlot'] as int?,
      fee: (data['fee'] as num?)?.toDouble(),
      hasMarker: data['reclassifiedFrom'] != null,
      markerAt:
          ((data['reclassifiedFrom'] as Map<String, dynamic>?)?['at']
                  as Timestamp?)
              ?.toDate(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
    );
  }

  @override
  Future<List<MoveRecord>> smsRecords() async {
    try {
      final snap = await _collection.where('source', isEqualTo: 'mpesa').get();
      return [for (final d in snap.docs) ?recordFrom(d)];
    } catch (e) {
      throw DataException.from(e);
    }
  }

  @override
  Future<bool> apply(MoveChange change) async {
    final r = change.record;
    final doc = _collection.doc(r.id);
    try {
      return await _collection.firestore.runTransaction((tx) async {
        final now = recordFrom(await tx.get(doc));
        if (now == null || !MoveFix.sameAsPreview(now, r)) return false;
        tx.update(doc, {
          'type': TransactionType.transfer.wireName,
          'category': 'transfer',
          'account': Account.mpesa.wireName,
          'toAccount': change.toAccount ?? FieldValue.delete(),
          'accountId': change.accountId,
          'toAccountId': change.toAccountId,
          'simSlot': change.fromSim,
          if (change.addFee != null) 'fee': change.addFee,
          // The existing undo marker: what the record was, stamped now.
          'reclassifiedFrom': {
            'type': r.type,
            'category': r.category,
            'at': FieldValue.serverTimestamp(),
          },
          'updatedAt': FieldValue.serverTimestamp(),
        });
        return true;
      });
    } catch (e) {
      throw DataException.from(e);
    }
  }

  @override
  Future<UndoOutcome> undo(MoveRecord original, MoveChange change) async {
    final doc = _collection.doc(original.id);
    Object put(Object? v) => v ?? FieldValue.delete();
    try {
      return await _collection.firestore.runTransaction((tx) async {
        final now = recordFrom(await tx.get(doc));
        final outcome = MoveFix.undoOutcome(now, change);
        if (outcome != UndoOutcome.undone) return outcome;
        tx.update(doc, {
          'type': original.type,
          'category': original.category,
          'account': put(original.account),
          'toAccount': put(original.toAccount),
          'accountId': put(original.accountId),
          'toAccountId': put(original.toAccountId),
          'simSlot': put(original.simSlot),
          'fee': put(original.fee),
          'reclassifiedFrom': FieldValue.delete(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
        return UndoOutcome.undone;
      });
    } catch (e) {
      throw DataException.from(e);
    }
  }
}

/// The opt-in "Fix moves between your accounts" for the signed-in profile.
///
/// - [preview] only reads: the profile's SMS records and this phone's own
///   messages. A record is proposed only when its code was "sent" on one of
///   the user's SIMs and "received" on the other for the same amount, or is
///   an agent cash withdrawal; it becomes a transfer between those
///   accounts, with the charge the SMS states added only where none is
///   counted yet. A withdrawal waits until Cash has a starting balance
///   dated after it, so old cash never shows as held today.
/// - [apply] backs up every original on this phone (read back and checked
///   first), then changes each record only if it is exactly as previewed.
///   Amounts, dates, codes, descriptions and notes never change.
/// - [undo] puts back exactly what each record held, while it still holds
///   what the fix set.
class MoveFix {
  MoveFix({
    required MoveFixRepository repository,
    required this._store,
    required this._gateway,
    required this._accounts,
    required this._transactions,
  }) : _repo = repository;

  final MoveFixRepository _repo;
  final MoveFixStore _store;
  final SmsGateway _gateway;
  final AccountStore? Function() _accounts;
  final List<TransactionModel> Function() _transactions;
  bool _busy = false;

  bool get isBusy => _busy;

  static const _single = {'income', 'expense'};

  /// [now] is exactly as the preview read it.
  static bool sameAsPreview(MoveRecord now, MoveRecord r) =>
      !now.hasMarker &&
      now.type == r.type &&
      now.category == r.category &&
      now.account == r.account &&
      now.toAccount == r.toAccount &&
      now.accountId == r.accountId &&
      now.toAccountId == r.toAccountId &&
      now.simSlot == r.simSlot &&
      now.fee == r.fee &&
      now.updatedAt == r.updatedAt;

  /// [now] still holds exactly what the fix set and wasn't edited since:
  /// its `updatedAt` is still the marker's time (any later save moves it).
  static bool stillFixed(MoveRecord now, MoveChange c) =>
      now.hasMarker &&
      now.markerAt != null &&
      now.updatedAt != null &&
      now.updatedAt == now.markerAt &&
      now.type == TransactionType.transfer.wireName &&
      now.category == 'transfer' &&
      now.accountId == c.accountId &&
      now.toAccountId == c.toAccountId &&
      now.toAccount == c.toAccount &&
      now.simSlot == c.fromSim &&
      now.fee == (c.addFee ?? c.record.fee) &&
      now.amount == c.record.amount;

  /// What Undo should do with [now] (null = deleted). No marker means the
  /// fix never changed it (or it was already put back): nothing to undo.
  static UndoOutcome undoOutcome(MoveRecord? now, MoveChange c) {
    if (now == null) return UndoOutcome.editedSince;
    if (!now.hasMarker) return UndoOutcome.notApplied;
    return stillFixed(now, c) ? UndoOutcome.undone : UndoOutcome.editedSince;
  }

  Future<MovePreview> preview() async {
    final records = await _repo.smsRecords();
    final accounts = _accounts();
    final candidates = [
      for (final r in records)
        if (_single.contains(r.type) && !r.hasMarker && r.reference != null) r,
    ];
    if (candidates.isEmpty || accounts == null) return const MovePreview();

    // This phone's messages per code: kind, SIM, amount and charge.
    final earliest = candidates
        .map((r) => r.date)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    final byCode = <String, List<(SmsTransaction, int?)>>{};
    try {
      final inbox = await _gateway.readInbox(
        senders: SmsParser.allSenders,
        since: earliest.subtract(const Duration(days: 1)),
      );
      for (final m in inbox) {
        final p = SmsParser.parse(sender: m.sender, body: m.body, date: m.date);
        if (p == null || p.kind.isFuliza) continue;
        byCode.putIfAbsent(p.reference, () => []).add((p, m.simSlot));
      }
    } catch (_) {
      return const MovePreview(
        skipped: {'No access to this phone\'s messages': 1},
      );
    }

    final skipped = <String, int>{};
    void skip(String why) => skipped[why] = (skipped[why] ?? 0) + 1;
    final changes = <MoveChange>[], blocked = <MoveChange>[];
    final cash = accounts.firstOf(AccountKind.cash, includeHidden: true);
    bool same(double a, double b) => Ledger.toCents(a) == Ledger.toCents(b);
    double? feeFor(MoveRecord r, SmsTransaction m) =>
        r.fee == null && (m.fee ?? 0) > 0 ? m.fee : null;

    for (final r in candidates) {
      final msgs = byCode[r.reference] ?? const [];
      final sent = msgs.where((m) => m.$1.kind == SmsTransactionKind.sent);
      final got = msgs.where(
        (m) =>
            m.$1.kind == SmsTransactionKind.received &&
            m.$1.source != TransactionSource.equity,
      );
      // Equity confirming money received from M-Pesa under this code.
      final intoBank = msgs.where(
        (m) =>
            m.$1.source == TransactionSource.equity &&
            m.$1.viaMobileMoney == r.reference,
      );
      final withdrawn = msgs.where(
        (m) => m.$1.kind == SmsTransactionKind.withdrawal,
      );
      if (sent.length == 1 && got.length == 1) {
        final (s, from) = sent.single;
        final (g, to) = got.single;
        if (from == null || to == null || from == to) continue;
        if (!same(s.amount, r.amount) || !same(g.amount, r.amount)) {
          skip('Amounts differ from the messages');
          continue;
        }
        final wallet = accounts.forSim(from, AccountKind.mobileMoney);
        final other = accounts.forSim(to, AccountKind.mobileMoney);
        if (wallet == null || other == null) {
          skip('No M-Pesa account for one of the SIMs');
          continue;
        }
        changes.add(
          MoveChange(
            record: r,
            kind: MoveKind.betweenSims,
            fromSim: from,
            toSim: to,
            accountId: wallet.id,
            toAccountId: other.id,
            addFee: feeFor(r, s),
          ),
        );
      } else if (r.type == 'expense' && intoBank.length == 1) {
        final (b, _) = intoBank.single;
        final mpesa = msgs.where(
          (m) => m.$1.source == TransactionSource.mpesa,
        );
        final from = r.simSlot ?? (mpesa.isEmpty ? null : mpesa.first.$2);
        if (from == null) {
          skip('Move into Equity: SIM unknown');
          continue;
        }
        if (!same(b.amount, r.amount)) {
          skip('Amounts differ from the messages');
          continue;
        }
        final wallet = accounts.forSim(from, AccountKind.mobileMoney);
        final bank = accounts.bank(AccountProvider.equity);
        if (wallet == null || bank == null) {
          skip('No M-Pesa or Equity account');
          continue;
        }
        changes.add(
          MoveChange(
            record: r,
            kind: MoveKind.intoBank,
            fromSim: from,
            accountId: wallet.id,
            toAccountId: bank.id,
            addFee: mpesa.isEmpty ? null : feeFor(r, mpesa.first.$1),
          ),
        );
      } else if (r.type == 'expense' &&
          withdrawn.length == 1 &&
          msgs.length == 1) {
        final (w, from) = withdrawn.single;
        if (from == null) {
          skip('Withdrawal: SIM unknown');
          continue;
        }
        if (!same(w.amount, r.amount)) {
          skip('Amounts differ from the messages');
          continue;
        }
        final wallet = accounts.forSim(from, AccountKind.mobileMoney);
        if (wallet == null || cash == null) {
          skip('No M-Pesa or Cash account');
          continue;
        }
        final change = MoveChange(
          record: r,
          kind: MoveKind.cashWithdrawal,
          fromSim: from,
          accountId: wallet.id,
          toAccountId: cash.id,
          addFee: feeFor(r, w),
        );
        // Cash's starting balance must be dated after the withdrawal.
        final start = cash.openingDate;
        if (cash.openingBalance == null ||
            start == null ||
            !start.isAfter(r.date)) {
          blocked.add(change);
        } else {
          changes.add(change);
        }
      }
    }
    changes.sort((a, b) => a.record.date.compareTo(b.record.date));
    blocked.sort((a, b) => a.record.date.compareTo(b.record.date));

    // Effects, by the app's own rules.
    final all = _transactions();
    final byId = {for (final t in all) t.id: t};
    final after = [
      for (final c in changes)
        if (byId[c.record.id] case final t?) corrected(t, c),
    ];
    final replaced = {for (final t in after) t.id: t};
    final next = [for (final t in all) replaced[t.id] ?? t];
    final monthKeys = {
      for (final c in changes)
        DateTime(c.record.date.year, c.record.date.month),
    }.toList()..sort();
    return MovePreview(
      changes: changes,
      blocked: blocked,
      skipped: skipped,
      months: [
        for (final m in monthKeys)
          MoveMonth(
            m,
            MonthlySummary.calculate(transactions: all, month: m),
            MonthlySummary.calculate(transactions: next, month: m),
          ),
      ],
      history: AccountAssignment.impact(accounts.all, all, after),
      cards: AccountAssignment.cardChange(accounts.all, all, after),
    );
  }

  /// [t] as the fix would leave it.
  static TransactionModel corrected(TransactionModel t, MoveChange c) =>
      TransactionModel(
        id: t.id,
        description: t.description,
        amount: t.amount,
        type: TransactionType.transfer,
        categoryId: 'transfer',
        date: t.date,
        note: t.note,
        source: t.source,
        reference: t.reference,
        smsText: t.smsText,
        account: Account.mpesa,
        toAccount: switch (c.kind) {
          MoveKind.cashWithdrawal => Account.cash,
          MoveKind.intoBank => Account.bank,
          MoveKind.betweenSims => null,
        },
        fee: c.addFee ?? t.fee,
        accountId: c.accountId,
        toAccountId: c.toAccountId,
        simSlot: c.fromSim,
      );

  Future<List<String>> changedIds() async => [...(await _store.changed()).keys];

  static Map<String, Object?> _changeJson(MoveChange c) => {
    'kind': c.kind.name,
    'fromSim': c.fromSim,
    'toSim': c.toSim,
    'setAccountId': c.accountId,
    'setToAccountId': c.toAccountId,
    'addFee': c.addFee,
  };

  /// The saved run log, newest last (kept across restarts).
  Future<List<String>> lastLog() => _store.log();

  /// Adds [line] to the saved run log, keeping the most recent 500 lines.
  Future<void> _logLine(List<String> log, String line) async {
    log.add('${DateTime.now().toIso8601String().substring(0, 19)} $line');
    if (log.length > 500) log.removeRange(0, log.length - 500);
    await _store.saveLog(log);
  }

  static const _backupError =
      'The backup could not be saved or checked on this phone. Nothing was '
      'changed.';

  Future<MoveRunResult> apply(MovePreview preview) async {
    if (_busy) return const MoveRunResult(error: 'Already running.');
    _busy = true;
    final log = <String>[];
    try {
      // 1. Backup on this phone, read back and checked before any write.
      // A record the fix has written keeps its first, verified original:
      // it is never replaced. (One only pending was never written, so it
      // still holds its original, read fresh by this preview.)
      final Map<String, bool> changed;
      try {
        changed = await _store.changed();
        final existing = await _store.backup();
        final kept = {
          for (final e in existing)
            if (changed[e['id']] == true) e['id']: e,
        };
        final backup = [
          for (final c in preview.changes)
            kept[c.record.id] ?? {...c.record.toJson(), 'fix': _changeJson(c)},
        ];
        await _store.saveBackup([
          ...existing.where((e) => !backup.any((b) => b['id'] == e['id'])),
          ...backup,
        ]);
        final readBack = await _store.backup();
        final ok = backup.every(
          (b) => readBack.any(
            (r) => r['id'] == b['id'] && jsonEncode(r) == jsonEncode(b),
          ),
        );
        if (!ok) return const MoveRunResult(error: _backupError);
        log.addAll(await _store.log());
        await _logLine(
          log,
          'Run started: ${preview.changes.length} records, backup checked',
        );
      } catch (_) {
        return const MoveRunResult(error: _backupError);
      }
      // 2. Each record: on the Undo list as pending first, then written only
      // if unchanged since the preview, then marked done. If the app stops
      // in between, Undo still reaches it, and tells a write that never
      // happened from one that did.
      var done = 0, skipped = 0;
      final runLog = <String>[];
      Future<void> note(String line) async {
        runLog.add(line);
        await _logLine(log, line);
      }

      for (final c in preview.changes) {
        final id = c.record.id;
        if (changed[id] == true) {
          skipped++;
          await note('$id: already fixed, left alone');
          continue;
        }
        changed[id] = false;
        await _store.saveChanged(changed);
        final bool applied;
        try {
          applied = await _repo.apply(c);
        } on DataException catch (e) {
          await note('$id: stopped, ${e.message}');
          return MoveRunResult(
            done: done,
            skipped: skipped,
            error: e.message,
            log: runLog,
          );
        }
        if (applied) {
          changed[id] = true;
          done++;
          await _store.saveChanged(changed);
          await note('$id: fixed');
        } else {
          changed.remove(id);
          skipped++;
          await _store.saveChanged(changed);
          await note('$id: changed since the preview, left alone');
        }
      }
      await note('Run finished: $done fixed, $skipped left alone');
      return MoveRunResult(done: done, skipped: skipped, log: runLog);
    } finally {
      _busy = false;
    }
  }

  Future<MoveRunResult> undo() async {
    if (_busy) return const MoveRunResult(error: 'Already running.');
    _busy = true;
    try {
      final Map<String, bool> changed;
      final Map<Object?, Map<String, Object?>> backup;
      final log = <String>[];
      try {
        changed = await _store.changed();
        backup = {for (final b in await _store.backup()) b['id']: b};
        log.addAll(await _store.log());
      } catch (_) {
        return const MoveRunResult(
          error:
              'The backup on this phone could not be read. Nothing was '
              'changed.',
        );
      }
      final runLog = <String>[];
      Future<void> note(String line) async {
        runLog.add(line);
        await _logLine(log, line);
      }

      await note('Undo started: ${changed.length} records');
      var done = 0, skipped = 0;
      for (final id in [...changed.keys]) {
        final b = backup[id];
        if (b == null) {
          // Not expected; kept on the list, nothing written.
          skipped++;
          await note('$id: no backup on this phone, left as it is');
          continue;
        }
        final original = _recordFromJson(b);
        final fix = (b['fix'] as Map).cast<String, Object?>();
        final change = MoveChange(
          record: original,
          kind: MoveKind.values.byName(fix['kind'] as String),
          fromSim: fix['fromSim'] as int,
          toSim: fix['toSim'] as int?,
          accountId: fix['setAccountId'] as String,
          toAccountId: fix['setToAccountId'] as String,
          addFee: (fix['addFee'] as num?)?.toDouble(),
        );
        final UndoOutcome outcome;
        try {
          outcome = await _repo.undo(original, change);
        } on DataException catch (e) {
          await note('$id: stopped, ${e.message}');
          return MoveRunResult(
            done: done,
            skipped: skipped,
            error: e.message,
            log: runLog,
          );
        }
        switch (outcome) {
          case UndoOutcome.undone:
            done++;
            await note('$id: put back');
          case UndoOutcome.notApplied:
            await note('$id: was never changed, nothing to put back');
          case UndoOutcome.editedSince:
            skipped++;
            await note('$id: edited since the fix, left as it is');
        }
        changed.remove(id);
        await _store.saveChanged(changed);
      }
      await note('Undo finished: $done put back, $skipped left alone');
      return MoveRunResult(done: done, skipped: skipped, log: runLog);
    } finally {
      _busy = false;
    }
  }

  static MoveRecord _recordFromJson(Map<String, Object?> b) => MoveRecord(
    id: b['id'] as String,
    type: b['type'] as String,
    category: b['category'] as String,
    amount: (b['amount'] as num).toDouble(),
    date: DateTime.parse(b['date'] as String),
    reference: b['reference'] as String?,
    account: b['account'] as String?,
    toAccount: b['toAccount'] as String?,
    accountId: b['accountId'] as String?,
    toAccountId: b['toAccountId'] as String?,
    simSlot: b['simSlot'] as int?,
    fee: (b['fee'] as num?)?.toDouble(),
  );
}
