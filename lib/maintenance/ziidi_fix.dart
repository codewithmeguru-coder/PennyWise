import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../accounts/account_repository.dart';
import '../accounts/money_account.dart';
import '../data/data_exception.dart';
import '../sms/sms_gateway.dart';
import 'inbox_sims.dart';
import 'ziidi_matcher.dart';

/// One stored transaction as the Ziidi fix sees it: the matcher's fields
/// plus what it may change (and must restore).
class ZiidiRecord {
  const ZiidiRecord({
    required this.id,
    required this.type,
    required this.category,
    required this.amount,
    required this.date,
    this.source,
    this.reference,
    this.smsText,
    this.createdAt,
    this.updatedAt,
    this.marker,
    this.simSlot,
    this.accountId,
    this.toAccountId,
  });

  final String id;
  final String type;
  final String category;
  final double amount;
  final DateTime date;
  final String? source, reference, smsText;
  final DateTime? createdAt, updatedAt;

  /// The undo marker (`reclassifiedFrom`): the type and category before the
  /// fix. Null when the record wasn't fixed.
  final ({String type, String category})? marker;
  final int? simSlot;
  final String? accountId, toAccountId;

  StoredSmsRecord get stored => StoredSmsRecord(
        id: id,
        type: type,
        source: source,
        reference: reference,
        smsText: smsText,
        createdAt: createdAt,
        updatedAt: updatedAt,
        hasReclassifiedFrom: marker != null,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'type': type,
        'category': category,
        'amount': amount,
        'date': date.toIso8601String(),
        'reference': reference,
        'simSlot': simSlot,
        'accountId': accountId,
        'toAccountId': toAccountId,
      };
}

/// The change for one record: new type and category, and the SIM and
/// accounts only when the phone's own records say which SIM it was.
class ZiidiChange {
  const ZiidiChange(this.record, this.check,
      {this.simSlot, this.accountId, this.toAccountId});

  final ZiidiRecord record;
  final ZiidiCheck check;
  final int? simSlot;
  final String? accountId, toAccountId;

  bool get addsSim => simSlot != null;
}

/// Reads and writes the records the fix touches (`users/{uid}/transactions`).
abstract class ZiidiFixRepository {
  /// Every stored transaction that came from an SMS.
  Future<List<ZiidiRecord>> smsRecords();

  /// Applies [change] if the record is still exactly as previewed (same
  /// type and category, no marker, never edited); otherwise writes nothing
  /// and returns false. Adds the undo marker, stamped by the server.
  Future<bool> apply(ZiidiChange change);

  /// Restores the type and category in the record's marker and removes the
  /// marker, and the SIM fields if [removeSim], but only while the record
  /// still has the type and category the fix gave it. Otherwise false.
  Future<bool> undo(String id, {required bool removeSim});
}

/// What the fix keeps on this phone, per profile: the backup of the
/// original records and the exact ids it changed (for Undo).
abstract class ZiidiFixStore {
  Future<List<Map<String, Object?>>> backup();
  Future<void> saveBackup(List<Map<String, Object?>> records);

  /// Changed ids, each with whether the fix added its SIM.
  Future<Map<String, bool>> changed();
  Future<void> saveChanged(Map<String, bool> changed);
}

class FirestoreZiidiFixRepository implements ZiidiFixRepository {
  FirestoreZiidiFixRepository({required this._uid, this._firestore});

  final String _uid;
  final FirebaseFirestore? _firestore;

  // Resolved on first use, so creating the fixer touches nothing.
  late final CollectionReference<Map<String, dynamic>> _collection =
      (_firestore ?? FirebaseFirestore.instance)
          .collection('users')
          .doc(_uid)
          .collection('transactions');

  /// A stored transaction as these fixes read it; null if it's gone.
  static ZiidiRecord? recordFrom(DocumentSnapshot<Map<String, dynamic>> d) {
    final data = d.data();
    if (data == null) return null;
    DateTime? time(String k) => (data[k] as Timestamp?)?.toDate();
    final marker = data['reclassifiedFrom'] as Map<String, dynamic>?;
    return ZiidiRecord(
      id: d.id,
      type: data['type'] as String? ?? '',
      category: data['category'] as String? ?? '',
      amount: (data['amount'] as num?)?.toDouble() ?? 0,
      date: time('date') ?? DateTime(1970),
      source: data['source'] as String?,
      reference: data['reference'] as String?,
      smsText: data['smsText'] as String?,
      createdAt: time('createdAt'),
      updatedAt: time('updatedAt'),
      marker: marker == null
          ? null
          : (
              type: marker['type'] as String,
              category: marker['category'] as String,
            ),
      simSlot: data['simSlot'] as int?,
      accountId: data['accountId'] as String?,
      toAccountId: data['toAccountId'] as String?,
    );
  }

  @override
  Future<List<ZiidiRecord>> smsRecords() async {
    try {
      final snap = await _collection.where('source', isEqualTo: 'mpesa').get();
      return [for (final d in snap.docs) ?recordFrom(d)];
    } catch (e) {
      throw DataException.from(e);
    }
  }

  @override
  Future<bool> apply(ZiidiChange change) async {
    final r = change.record;
    final doc = _collection.doc(r.id);
    try {
      return await _collection.firestore.runTransaction((tx) async {
        final now = recordFrom(await tx.get(doc));
        if (now == null ||
            now.marker != null ||
            now.type != r.type ||
            now.category != r.category ||
            now.updatedAt != r.updatedAt) {
          return false; // changed since the preview: leave it
        }
        tx.update(doc, {
          'type': change.check.newType,
          'category': change.check.newCategory,
          'reclassifiedFrom': {
            'type': r.type,
            'category': r.category,
            'at': FieldValue.serverTimestamp(),
          },
          if (change.simSlot != null) 'simSlot': change.simSlot,
          if (change.accountId != null) 'accountId': change.accountId,
          if (change.toAccountId != null) 'toAccountId': change.toAccountId,
          'updatedAt': FieldValue.serverTimestamp(),
        });
        return true;
      });
    } catch (e) {
      throw DataException.from(e);
    }
  }

  @override
  Future<bool> undo(String id, {required bool removeSim}) async {
    final doc = _collection.doc(id);
    try {
      return await _collection.firestore.runTransaction((tx) async {
        final now = recordFrom(await tx.get(doc));
        final marker = now?.marker;
        if (now == null || marker == null) return false;
        final check = ZiidiMatcher.check(ZiidiRecord(
          id: now.id,
          type: marker.type,
          category: marker.category,
          amount: now.amount,
          date: now.date,
          source: now.source,
          reference: now.reference,
          smsText: now.smsText,
          createdAt: now.createdAt,
          updatedAt: now.createdAt,
        ).stored);
        if (now.type != check.newType || now.category != check.newCategory) {
          return false; // edited after the fix: leave it
        }
        tx.update(doc, {
          'type': marker.type,
          'category': marker.category,
          'reclassifiedFrom': FieldValue.delete(),
          if (removeSim) ...{
            'simSlot': FieldValue.delete(),
            'accountId': FieldValue.delete(),
            'toAccountId': FieldValue.delete(),
          },
          'updatedAt': FieldValue.serverTimestamp(),
        });
        return true;
      });
    } catch (e) {
      throw DataException.from(e);
    }
  }
}

class SharedPrefsZiidiFixStore implements ZiidiFixStore {
  SharedPrefsZiidiFixStore({required String uid}) : _prefix = 'ziidi_fix_${uid}_';

  /// The same store kept under [prefix], for another fix of the same kind.
  SharedPrefsZiidiFixStore.prefixed(this._prefix);

  final String _prefix;

  @override
  Future<List<Map<String, Object?>>> backup() async {
    final raw = (await SharedPreferences.getInstance())
            .getString('${_prefix}backup') ??
        '[]';
    return [
      for (final r in jsonDecode(raw) as List) (r as Map).cast<String, Object?>(),
    ];
  }

  @override
  Future<void> saveBackup(List<Map<String, Object?>> records) async =>
      (await SharedPreferences.getInstance())
          .setString('${_prefix}backup', jsonEncode(records));

  @override
  Future<Map<String, bool>> changed() async {
    final raw = (await SharedPreferences.getInstance())
            .getString('${_prefix}changed') ??
        '{}';
    return (jsonDecode(raw) as Map).cast<String, bool>();
  }

  @override
  Future<void> saveChanged(Map<String, bool> changed) async =>
      (await SharedPreferences.getInstance())
          .setString('${_prefix}changed', jsonEncode(changed));
}

/// The preview: what the fix would change, and what it leaves alone.
class ZiidiPreview {
  const ZiidiPreview(this.changes, this.skipped, {this.edited = const []});

  final List<ZiidiChange> changes;

  /// Real Ziidi messages the user edited after import (e.g. still saved as
  /// an expense). Not in [changes]: fixed only with [ZiidiFixer.fixEdited],
  /// after the user confirms.
  final List<ZiidiChange> edited;

  /// Ziidi messages it won't change, with why (already fixed, edited...).
  final Map<String, int> skipped;

  int get contributions =>
      changes.where((c) => c.check.direction == ZiidiDirection.sent).length;
  int get withdrawals => changes.length - contributions;
  double get contributed => _sum(ZiidiDirection.sent);
  double get withdrawn => _sum(ZiidiDirection.received);
  int get withSim => changes.where((c) => c.addsSim).length;

  double _sum(ZiidiDirection d) => changes
      .where((c) => c.check.direction == d)
      .fold(0, (s, c) => s + c.record.amount);
}

/// What a fix or Undo did.
class ZiidiRunResult {
  const ZiidiRunResult({this.done = 0, this.skipped = 0, this.error});
  final int done, skipped;
  final String? error;
}

/// The opt-in "Fix old Ziidi records" for the signed-in profile.
///
/// - [preview] only reads: stored SMS records, and the phone's inbox for
///   which SIM each message came to. Nothing is written.
/// - [fix] first saves a backup of every record it will touch on this phone
///   and reads it back to check it; only then changes each record (type and
///   category, plus the undo marker; the SIM only with evidence) if it is
///   still exactly as previewed. Ids, amounts, dates and codes never change.
/// - [undo] restores exactly the records this fix changed, from their own
///   undo marker, skipping any edited since.
class ZiidiFixer {
  ZiidiFixer({
    required ZiidiFixRepository repository,
    required this._store,
    required this._gateway,
    required this._accounts,
  }) : _repo = repository;

  final ZiidiFixRepository _repo;
  final ZiidiFixStore _store;
  final SmsGateway _gateway;
  final AccountResolver? Function() _accounts;
  bool _busy = false;

  bool get isBusy => _busy;

  /// The SIM of each message code, from the phone's own records.
  Future<Map<String, int?>> _simsByCode(DateTime since) =>
      simsByCode(_gateway, since);

  Future<ZiidiPreview> preview() async {
    final records = await _repo.smsRecords();
    // Originals this fix backed up on this phone. A record put back by its
    // own Undo looks "edited" (Undo stamps updatedAt), but if it still has
    // exactly the backed-up type and category and no marker, it is offered
    // again. One changed by the user since (e.g. re-categorised) is not.
    final backedUp = {for (final b in await _store.backup()) b['id']: b};
    final candidates = <(ZiidiRecord, ZiidiCheck)>[];
    final editedCandidates = <(ZiidiRecord, ZiidiCheck)>[];
    final skipped = <String, int>{};
    for (final r in records) {
      var check = ZiidiMatcher.check(r.stored);
      if (!check.isZiidi) continue;
      final original = backedUp[r.id];
      if (!check.change &&
          check.reason == 'Edited by you after import' &&
          original != null &&
          r.marker == null &&
          original['type'] == r.type &&
          original['category'] == r.category &&
          original['reference'] == r.reference &&
          original['amount'] == r.amount) {
        check = ZiidiCheck.change(check.direction!);
      }
      if (check.change) {
        candidates.add((r, check));
      } else if (check.reason == 'Edited by you after import' &&
          r.marker == null) {
        // Still left alone by fix(), and counted as such; also offered on
        // its own, fixed only if the user confirms it.
        skipped[check.reason!] = (skipped[check.reason!] ?? 0) + 1;
        editedCandidates.add((r, ZiidiCheck.change(check.direction!)));
      } else {
        skipped[check.reason!] = (skipped[check.reason!] ?? 0) + 1;
      }
    }
    final all = [...candidates, ...editedCandidates];
    if (all.isEmpty) return ZiidiPreview(const [], skipped);
    final earliest =
        all.map((c) => c.$1.date).reduce((a, b) => a.isBefore(b) ? a : b);
    final sims = await _simsByCode(earliest);
    final accounts = _accounts();
    ZiidiChange changeFor(ZiidiRecord r, ZiidiCheck check) {
      // Only a record that has no SIM yet gets one, and only from evidence.
      final slot = r.simSlot == null && r.accountId == null
          ? sims[r.reference]
          : null;
      final wallet = accounts?.forSim(slot, AccountKind.mobileMoney)?.id;
      final ziidi = accounts?.forSim(slot, AccountKind.savings)?.id;
      final both = wallet != null && ziidi != null;
      return ZiidiChange(r, check,
          simSlot: slot,
          accountId: both ? wallet : null,
          toAccountId: both ? ziidi : null);
    }

    final changes = [for (final (r, c) in candidates) changeFor(r, c)]
      ..sort((a, b) => a.record.date.compareTo(b.record.date));
    final edited = [for (final (r, c) in editedCandidates) changeFor(r, c)]
      ..sort((a, b) => a.record.date.compareTo(b.record.date));
    return ZiidiPreview(changes, skipped, edited: edited);
  }

  Future<List<String>> changedIds() async => [...(await _store.changed()).keys];

  /// Fixes the records the user edited after import, which the user has
  /// confirmed: the same backup, per-record check and Undo as [fix].
  Future<ZiidiRunResult> fixEdited(ZiidiPreview preview) =>
      fix(ZiidiPreview(preview.edited, const {}));

  Future<ZiidiRunResult> fix(ZiidiPreview preview) async {
    if (_busy) return const ZiidiRunResult(error: 'Already running.');
    _busy = true;
    try {
      // 1. Backup on this phone, read back and checked before any write.
      final backup = [for (final c in preview.changes) c.record.toJson()];
      final existing = await _store.backup();
      final merged = [
        ...existing.where((e) => !backup.any((b) => b['id'] == e['id'])),
        ...backup,
      ];
      await _store.saveBackup(merged);
      final readBack = await _store.backup();
      final ok = backup.every((b) => readBack.any(
          (r) => r['id'] == b['id'] && jsonEncode(r) == jsonEncode(b)));
      if (!ok) {
        return const ZiidiRunResult(
            error: 'The backup could not be checked. Nothing was changed.');
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
          changed[c.record.id] = c.addsSim;
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
      var done = 0, skipped = 0;
      for (final entry in [...changed.entries]) {
        final bool undone;
        try {
          undone = await _repo.undo(entry.key, removeSim: entry.value);
        } on DataException catch (e) {
          return ZiidiRunResult(done: done, skipped: skipped, error: e.message);
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
