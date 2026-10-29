import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../accounts/account_repository.dart';
import '../accounts/money_account.dart';
import '../data/data_exception.dart';
import '../models/transaction_model.dart';
import '../sms/sms_gateway.dart';
import 'account_assignment.dart';
import 'inbox_sims.dart';
import 'ziidi_fix.dart';

/// Where the SIM for a backfilled record comes from.
enum SimEvidence {
  /// Recorded when the SMS was imported (the account just didn't exist).
  stored,

  /// The phone's own SMS records, matched by the message's code.
  inbox,
}

/// One record the backfill would give an account.
class BackfillChange {
  const BackfillChange(
    this.record,
    this.simSlot,
    this.accountId,
    this.evidence, {
    this.accountName,
    this.toAccountId,
  });

  final ZiidiRecord record;

  /// The account's name, shown in the preview.
  final String? accountName;
  final int simSlot;
  final String accountId;

  /// The other side of a move between the user's own accounts (savings,
  /// a loan repayment, a Fuliza loan); null for income and spending.
  final String? toAccountId;
  final SimEvidence evidence;

  /// The record had no SIM, so the backfill sets it too.
  bool get setsSim => record.simSlot == null;
}

/// The preview: what would change, what is left alone and why, the past
/// income minus spending the records add to each account's history, and
/// how each card's displayed balance would move.
class BackfillPreview {
  const BackfillPreview(
    this.changes,
    this.skipped,
    this.impact, {
    this.impactByEvidence = const {},
    this.cardChange = const {},
    this.cardChangeByEvidence = const {},
  });

  final List<BackfillChange> changes;
  final Map<String, int> skipped;

  /// History: income minus spending the records add to each account's own
  /// history (its calculated total), per account, only where it changes.
  /// Not a change to the balance a card shows: see [cardChange].
  final Map<MoneyAccount, double> impact;

  /// [impact] for each group on its own (applied separately).
  final Map<SimEvidence, Map<MoneyAccount, double>> impactByEvidence;

  /// The change in each card's displayed balance (as on the card and
  /// Home), only where it changes.
  final Map<MoneyAccount, double> cardChange;

  /// [cardChange] for each group on its own.
  final Map<SimEvidence, Map<MoneyAccount, double>> cardChangeByEvidence;

  int count(SimEvidence e) => changes.where((c) => c.evidence == e).length;

  /// Just one group, e.g. the records whose SIM was recorded at import,
  /// with that group's own card changes: what applying it would do.
  BackfillPreview only(SimEvidence e) => BackfillPreview(
    [
      for (final c in changes)
        if (c.evidence == e) c,
    ],
    const {},
    impactByEvidence[e] ?? const {},
    cardChange: cardChangeByEvidence[e] ?? const {},
  );

  /// Changes per account id.
  Map<String, int> get perAccount {
    final out = <String, int>{};
    for (final c in changes) {
      out[c.accountId] = (out[c.accountId] ?? 0) + 1;
    }
    return out;
  }
}

/// Firestore side of the backfill: read SMS records, and set or remove only
/// `accountId` (and `simSlot`) on one record if it's exactly as previewed.
abstract class SimBackfillRepository {
  Future<List<ZiidiRecord>> smsRecords();

  /// False (nothing written) if the record changed since the preview.
  Future<bool> apply(BackfillChange change);

  /// Removes what [apply] set, if the record still has it and its type and
  /// category are as backed up. False otherwise (left as it is).
  Future<bool> undo(
    String id, {
    required String accountId,
    String? toAccountId,
    required bool removeSim,
    required String type,
    required String category,
  });
}

class FirestoreSimBackfillRepository implements SimBackfillRepository {
  FirestoreSimBackfillRepository({required this._uid, this._firestore});

  final String _uid;
  final FirebaseFirestore? _firestore;

  late final CollectionReference<Map<String, dynamic>> _collection =
      (_firestore ?? FirebaseFirestore.instance)
          .collection('users')
          .doc(_uid)
          .collection('transactions');

  @override
  Future<List<ZiidiRecord>> smsRecords() async {
    try {
      final snap = await _collection.where('source', isEqualTo: 'mpesa').get();
      return [
        for (final d in snap.docs) ?FirestoreZiidiFixRepository.recordFrom(d),
      ];
    } catch (e) {
      throw DataException.from(e);
    }
  }

  @override
  Future<bool> apply(BackfillChange change) async {
    final r = change.record;
    final doc = _collection.doc(r.id);
    try {
      return await _collection.firestore.runTransaction((tx) async {
        final now = FirestoreZiidiFixRepository.recordFrom(await tx.get(doc));
        if (now == null ||
            now.accountId != null ||
            now.toAccountId != null ||
            now.simSlot != r.simSlot ||
            now.type != r.type ||
            now.category != r.category ||
            now.updatedAt != r.updatedAt) {
          return false; // changed since the preview: leave it
        }
        tx.update(doc, {
          'accountId': change.accountId,
          if (change.toAccountId != null) 'toAccountId': change.toAccountId,
          if (change.setsSim) 'simSlot': change.simSlot,
          'updatedAt': FieldValue.serverTimestamp(),
        });
        return true;
      });
    } catch (e) {
      throw DataException.from(e);
    }
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
    final doc = _collection.doc(id);
    try {
      return await _collection.firestore.runTransaction((tx) async {
        final now = FirestoreZiidiFixRepository.recordFrom(await tx.get(doc));
        if (now == null ||
            now.accountId != accountId ||
            now.toAccountId != toAccountId ||
            now.type != type ||
            now.category != category) {
          return false; // edited since: leave it
        }
        tx.update(doc, {
          'accountId': FieldValue.delete(),
          if (toAccountId != null) 'toAccountId': FieldValue.delete(),
          if (removeSim) 'simSlot': FieldValue.delete(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
        return true;
      });
    } catch (e) {
      throw DataException.from(e);
    }
  }
}

/// The opt-in "Fill in SIMs" for SMS records with no account.
///
/// - [preview] only reads (stored records, the phone's inbox, the accounts).
///   The SIM comes from the record itself or from the phone's own record of
///   that message code; it is never guessed. Only income, expense and
///   refund records (one account side) are considered.
/// - [apply] backs up every record first and checks the backup, then sets
///   only `accountId` (and `simSlot` if missing) on each record that is
///   still exactly as previewed. Category and type never change.
/// - [undo] removes exactly what [apply] set, skipping records edited since.
class SimBackfill {
  SimBackfill({
    required this._repo,
    required this._store,
    required this._gateway,
    required this._accounts,
    required this._transactions,
  });

  final SimBackfillRepository _repo;
  final ZiidiFixStore _store;
  final SmsGateway _gateway;
  final AccountStore? Function() _accounts;
  final List<TransactionModel> Function() _transactions;
  bool _busy = false;

  bool get isBusy => _busy;

  static const _single = {'income', 'expense', 'refund'};

  Future<BackfillPreview> preview() async {
    final records = await _repo.smsRecords();
    final accounts = _accounts();
    final skipped = <String, int>{};
    void skip(String why) => skipped[why] = (skipped[why] ?? 0) + 1;

    final candidates = [
      for (final r in records)
        if (r.accountId == null && r.toAccountId == null) r,
    ];
    final needInbox = candidates.where((r) => r.simSlot == null).toList();
    final sims = needInbox.isEmpty
        ? const <String, int?>{}
        : await simsByCode(
            _gateway,
            needInbox
                .map((r) => r.date)
                .reduce((a, b) => a.isBefore(b) ? a : b),
          );

    final changes = <BackfillChange>[];
    for (final r in candidates) {
      final type = TransactionType.fromWire(r.type);
      if (type == null) continue;
      // A transfer (other than a Fuliza loan) needs the user to say where
      // the money went, whatever the SIM: it goes to the form.
      if (type == TransactionType.transfer && !r.id.endsWith('_FULIZA')) {
        skip('Needs two accounts: edit it in the form');
        continue;
      }
      final evidence = r.simSlot != null
          ? SimEvidence.stored
          : SimEvidence.inbox;
      final slot = r.simSlot ?? sims[r.reference];
      if (slot == null) {
        skip('SIM unknown (not in this phone\'s messages)');
        continue;
      }
      if (!_single.contains(r.type)) {
        // A move between the user's own accounts: both sides follow from
        // the SIM (its M-Pesa and its Ziidi or Fuliza), or it waits for the
        // form (e.g. a transfer to Cash or the other SIM).
        final pair = accounts == null
            ? null
            : AccountAssignment.pairForSim(type, r.id, slot, accounts);
        if (pair == null) {
          skip('Needs two accounts: edit it in the form');
          continue;
        }
        changes.add(BackfillChange(r, slot, pair.from.id, evidence,
            accountName: '${pair.from.name} → ${pair.to.name}',
            toAccountId: pair.to.id));
        continue;
      }
      final account = accounts?.forSim(slot, AccountKind.mobileMoney);
      final wallet = account?.id;
      if (wallet == null) {
        skip('No M-Pesa account for SIM ${slot + 1}');
        continue;
      }
      changes.add(
        BackfillChange(r, slot, wallet, evidence, accountName: account?.name),
      );
    }
    changes.sort((a, b) => a.record.date.compareTo(b.record.date));

    // How each card would move, by the cards' own rules.
    final all = _transactions();
    final byId = {for (final t in all) t.id: t};
    List<TransactionModel> afterOf(Iterable<BackfillChange> some) => [
      for (final c in some)
        if (byId[c.record.id] case final t?)
          t.withAccount(
            c.accountId,
            simSlot: c.simSlot,
            toAccountId: c.toAccountId,
          ),
    ];
    Map<MoneyAccount, double> impactOf(Iterable<BackfillChange> some) =>
        accounts == null
        ? <MoneyAccount, double>{}
        : AccountAssignment.impact(accounts.all, all, afterOf(some));
    Map<MoneyAccount, double> cardOf(Iterable<BackfillChange> some) =>
        accounts == null
        ? <MoneyAccount, double>{}
        : AccountAssignment.cardChange(accounts.all, all, afterOf(some));
    return BackfillPreview(
      changes,
      skipped,
      impactOf(changes),
      impactByEvidence: {
        for (final e in SimEvidence.values)
          e: impactOf(changes.where((c) => c.evidence == e)),
      },
      cardChange: cardOf(changes),
      cardChangeByEvidence: {
        for (final e in SimEvidence.values)
          e: cardOf(changes.where((c) => c.evidence == e)),
      },
    );
  }

  Future<List<String>> changedIds() async => [...(await _store.changed()).keys];

  Future<ZiidiRunResult> apply(BackfillPreview preview) async {
    if (_busy) return const ZiidiRunResult(error: 'Already running.');
    _busy = true;
    try {
      // 1. Backup on this phone, read back and checked before any write.
      final backup = [
        for (final c in preview.changes)
          {
            ...c.record.toJson(),
            'category': c.record.category,
            'setAccountId': c.accountId,
            'setToAccountId': c.toAccountId,
            'setSim': c.setsSim,
          },
      ];
      final existing = await _store.backup();
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
      if (!ok) {
        return const ZiidiRunResult(
          error: 'The backup could not be checked. Nothing was changed.',
        );
      }
      // 2. Each record, only if unchanged since the preview.
      final changed = await _store.changed();
      var done = 0, skipped = 0;
      for (final c in preview.changes) {
        if (changed.containsKey(c.record.id)) {
          skipped++;
          continue;
        }
        final bool applied;
        try {
          applied = await _repo.apply(c);
        } on DataException catch (e) {
          return ZiidiRunResult(done: done, skipped: skipped, error: e.message);
        }
        if (applied) {
          changed[c.record.id] = c.setsSim;
          await _store.saveChanged(changed);
          done++;
        } else {
          skipped++;
        }
      }
      return ZiidiRunResult(done: done, skipped: skipped);
    } finally {
      _busy = false;
    }
  }

  Future<ZiidiRunResult> undo() async {
    if (_busy) return const ZiidiRunResult(error: 'Already running.');
    _busy = true;
    try {
      final changed = await _store.changed();
      final backup = {for (final b in await _store.backup()) b['id']: b};
      var done = 0, skipped = 0;
      for (final entry in [...changed.entries]) {
        final b = backup[entry.key];
        bool undone = false;
        if (b != null) {
          try {
            undone = await _repo.undo(
              entry.key,
              accountId: b['setAccountId'] as String,
              toAccountId: b['setToAccountId'] as String?,
              removeSim: entry.value,
              type: b['type'] as String,
              category: b['category'] as String,
            );
          } on DataException catch (e) {
            return ZiidiRunResult(
              done: done,
              skipped: skipped,
              error: e.message,
            );
          }
        }
        undone ? done++ : skipped++;
        changed.remove(entry.key);
        await _store.saveChanged(changed);
      }
      return ZiidiRunResult(done: done, skipped: skipped);
    } finally {
      _busy = false;
    }
  }
}
