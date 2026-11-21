import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../data/data_exception.dart';
import '../data/write_limit.dart';
import 'anchor_log.dart';
import 'money_account.dart';

/// Read / write one user's accounts (`users/{uid}/accounts`).
abstract class AccountRepository {
  Stream<List<MoneyAccount>> watchAll();

  /// Creates or replaces [account] (its id is the document id).
  Future<void> save(MoneyAccount account);

  /// Creates every account in [accounts] that doesn't exist yet.
  Future<void> createMissing(List<MoneyAccount> accounts);

  /// The history of starting-balance changes, oldest first
  /// (`users/{uid}/balanceAnchors`).
  Future<List<AnchorChange>> anchorHistory();

  /// Saves [updated] and records [change] in one atomic write. False (and
  /// nothing written) if the account already holds this starting balance,
  /// so a retry after an unconfirmed save doesn't record it twice.
  Future<bool> saveWithAnchor(MoneyAccount updated, AnchorChange change);

  /// Saves [restored] and marks [change] undone, atomically. False (and
  /// nothing written) if it is already undone or the account changed since.
  Future<bool> undoAnchor(MoneyAccount restored, AnchorChange change);
}

class FirestoreAccountRepository implements AccountRepository {
  FirestoreAccountRepository({required String uid, FirebaseFirestore? firestore})
      : _uid = uid,
        _collection = (firestore ?? FirebaseFirestore.instance)
            .collection('users')
            .doc(uid)
            .collection('accounts'),
        _anchors = (firestore ?? FirebaseFirestore.instance)
            .collection('users')
            .doc(uid)
            .collection('balanceAnchors');

  final String _uid;
  final CollectionReference<Map<String, dynamic>> _collection;
  final CollectionReference<Map<String, dynamic>> _anchors;

  @override
  Stream<List<MoneyAccount>> watchAll() => _collection
      .snapshots()
      .map((s) => s.docs.map(_fromDoc).whereType<MoneyAccount>().toList())
      .handleError((Object e) => throw DataException.from(e));

  static Map<String, dynamic> _fields(MoneyAccount a) => {
        'name': a.name,
        'kind': a.kind.wireName,
        'provider': a.provider.wireName,
        if (a.simSlot != null) 'simSlot': a.simSlot,
        if (a.parentId != null) 'parentId': a.parentId,
        if (a.openingBalance != null) 'openingBalance': a.openingBalance,
        if (a.openingDate != null)
          'openingDate': Timestamp.fromDate(a.openingDate!),
        'active': a.active,
        'order': a.order,
        if (a.creditLimit != null) 'creditLimit': a.creditLimit,
        if (a.creditLimit != null && a.creditLimitUpdatedAt != null)
          'creditLimitUpdatedAt': Timestamp.fromDate(a.creditLimitUpdatedAt!),
        'updatedAt': FieldValue.serverTimestamp(),
      };

  @override
  Future<void> save(MoneyAccount account) async {
    final doc = _collection.doc(account.id);
    try {
      await _collection.firestore.runTransaction((tx) async {
        final existing = await tx.get(doc);
        if (existing.exists) {
          await WriteLimit.claimEdit(
            tx,
            WriteLimit.editCounterOf(_collection),
            'accounts/${doc.id}',
          );
          tx.update(doc, {
            ..._fields(account),
            // update() merges: clear optional fields the user removed.
            if (account.openingBalance == null)
              'openingBalance': FieldValue.delete(),
            if (account.openingDate == null) 'openingDate': FieldValue.delete(),
            ..._clearedLimit(account),
          });
        } else {
          await _create(tx, account);
        }
      });
    } catch (e) {
      throw DataException.from(e);
    }
  }

  /// Creates [account] in [tx], claiming one new record from today's write
  /// limit (call after the transaction's other reads).
  Future<void> _create(Transaction tx, MoneyAccount account) async {
    await WriteLimit.claim(
      tx,
      WriteLimit.counterOf(_collection),
      'accounts/${account.id}',
    );
    tx.set(_collection.doc(account.id), {
      ..._fields(account),
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  @override
  Future<void> createMissing(List<MoneyAccount> accounts) async {
    try {
      // One account per Firestore transaction, as each new account claims
      // its own write. Stopping halfway is safe: running it again creates
      // only the ones still missing.
      for (final account in accounts) {
        final doc = _collection.doc(account.id);
        await _collection.firestore.runTransaction((tx) async {
          if ((await tx.get(doc)).exists) return;
          await _create(tx, account);
        });
      }
    } on DataException {
      rethrow;
    } catch (e) {
      throw DataException.from(e);
    }
  }

  /// The account document's fields for an update of [account]: like
  /// [save], clearing optional fields the account no longer has.
  static Map<String, dynamic> _updateFields(MoneyAccount account) => {
        ..._fields(account),
        if (account.openingBalance == null)
          'openingBalance': FieldValue.delete(),
        if (account.openingDate == null) 'openingDate': FieldValue.delete(),
        ..._clearedLimit(account),
      };

  /// Removes a loan limit the user cleared.
  static Map<String, dynamic> _clearedLimit(MoneyAccount account) => {
        if (account.creditLimit == null) 'creditLimit': FieldValue.delete(),
        if (account.creditLimit == null ||
            account.creditLimitUpdatedAt == null)
          'creditLimitUpdatedAt': FieldValue.delete(),
      };

  Map<String, dynamic> _anchorFields(AnchorChange c) => {
        'uid': _uid,
        'accountId': c.accountId,
        if (c.after != null && c.afterDate != null) ...{
          'amount': c.after,
          'effectiveAt': Timestamp.fromDate(c.afterDate!),
        },
        if (c.before != null && c.beforeDate != null) ...{
          'previousAmount': c.before,
          'previousEffectiveAt': Timestamp.fromDate(c.beforeDate!),
        },
        'currency': 'KES',
        'reason': c.reason,
        'undone': false,
        'createdAt': FieldValue.serverTimestamp(),
      };

  @override
  Future<List<AnchorChange>> anchorHistory() async {
    try {
      final snap = await _anchors.orderBy('createdAt').get();
      return [for (final d in snap.docs) ?_anchorFromDoc(d)];
    } catch (e) {
      throw DataException.from(e);
    }
  }

  static AnchorChange? _anchorFromDoc(
      QueryDocumentSnapshot<Map<String, dynamic>> d) {
    try {
      final data = d.data();
      return AnchorChange(
        id: d.id,
        accountId: data['accountId'] as String,
        // Pending server time on a just-made local write: now.
        at: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
        reason: data['reason'] as String,
        before: (data['previousAmount'] as num?)?.toDouble(),
        beforeDate: (data['previousEffectiveAt'] as Timestamp?)?.toDate(),
        after: (data['amount'] as num?)?.toDouble(),
        afterDate: (data['effectiveAt'] as Timestamp?)?.toDate(),
        undone: data['undone'] as bool? ?? false,
      );
    } catch (e) {
      debugPrint('Skipping malformed balance anchor ${d.id}');
      return null;
    }
  }

  static double? _amount(Map<String, dynamic>? data) =>
      (data?['openingBalance'] as num?)?.toDouble();
  static DateTime? _date(Map<String, dynamic>? data) =>
      (data?['openingDate'] as Timestamp?)?.toDate();

  static bool _holds(
          Map<String, dynamic>? data, double? amount, DateTime? date) =>
      (_amount(data) == null) == (amount == null) &&
      (amount == null || (_amount(data)! * 100).round() == (amount * 100).round()) &&
      _date(data)?.millisecondsSinceEpoch == date?.millisecondsSinceEpoch;

  @override
  Future<bool> saveWithAnchor(MoneyAccount updated, AnchorChange change) async {
    final doc = _collection.doc(updated.id);
    try {
      return await _collection.firestore.runTransaction((tx) async {
        final existing = await tx.get(doc);
        if (!existing.exists) {
          throw const DataException('That account no longer exists.');
        }
        if (_holds(existing.data(), updated.openingBalance,
            updated.openingDate)) {
          return false; // already saved (e.g. a retry)
        }
        final previous = existing.data();
        // The account update claims one edit, and the new history record
        // one new record (two counters, one claim each).
        await WriteLimit.claimEditAndNew(
          tx,
          editCounter: WriteLimit.editCounterOf(_collection),
          editPath: 'accounts/${doc.id}',
          counter: WriteLimit.counterOf(_collection),
          newPath: 'balanceAnchors/${change.id}',
        );
        tx.update(doc, _updateFields(updated));
        tx.set(
          _anchors.doc(change.id),
          _anchorFields(AnchorChange(
            id: change.id,
            accountId: change.accountId,
            at: change.at,
            reason: change.reason,
            // What the account really held, as read in this transaction.
            before: _amount(previous),
            beforeDate: _amount(previous) == null ? null : _date(previous),
            after: change.after,
            afterDate: change.afterDate,
          )),
        );
        return true;
      });
    } on DataException {
      rethrow;
    } catch (e) {
      throw DataException.from(e);
    }
  }

  @override
  Future<bool> undoAnchor(MoneyAccount restored, AnchorChange change) async {
    final doc = _collection.doc(restored.id);
    final anchor = _anchors.doc(change.id);
    try {
      return await _collection.firestore.runTransaction((tx) async {
        final record = await tx.get(anchor);
        final account = await tx.get(doc);
        if (!record.exists ||
            record.data()?['undone'] == true ||
            !account.exists ||
            !_holds(account.data(), change.after, change.afterDate)) {
          return false; // undone already, or changed since
        }
        await WriteLimit.claimEdit(
          tx,
          WriteLimit.editCounterOf(_collection),
          'accounts/${doc.id}',
        );
        tx.update(doc, _updateFields(restored));
        tx.update(anchor, {
          'undone': true,
          'undoneAt': FieldValue.serverTimestamp(),
        });
        return true;
      });
    } catch (e) {
      throw DataException.from(e);
    }
  }

  static MoneyAccount? _fromDoc(QueryDocumentSnapshot<Map<String, dynamic>> d) {
    try {
      final data = d.data();
      final kind = AccountKind.fromWire(data['kind'] as String?);
      if (kind == null) return null;
      return MoneyAccount(
        id: d.id,
        name: data['name'] as String,
        kind: kind,
        provider: AccountProvider.fromWire(data['provider'] as String?) ??
            AccountProvider.none,
        simSlot: data['simSlot'] as int?,
        parentId: data['parentId'] as String?,
        openingBalance: (data['openingBalance'] as num?)?.toDouble(),
        openingDate: (data['openingDate'] as Timestamp?)?.toDate(),
        active: data['active'] as bool? ?? true,
        order: data['order'] as int? ?? 0,
        creditLimit: (data['creditLimit'] as num?)?.toDouble(),
        creditLimitUpdatedAt:
            (data['creditLimitUpdatedAt'] as Timestamp?)?.toDate(),
      );
    } catch (e) {
      debugPrint('Skipping malformed account ${d.id}');
      return null;
    }
  }
}

/// Finds the user's own account for an SMS.
abstract class AccountResolver {
  /// The account of [kind] for SIM [slot] (0 = SIM 1, 1 = SIM 2), or null
  /// if the SIM is unknown or no such account exists. Never the other SIM.
  MoneyAccount? forSim(int? slot, AccountKind kind,
      {AccountProvider provider = AccountProvider.safaricom});

  /// The first active account of [kind] not tied to a SIM (e.g. Cash), or
  /// with [includeHidden] the first such account even if hidden.
  MoneyAccount? firstOf(AccountKind kind, {bool includeHidden = false});

  /// The first active bank account with [provider] (e.g. Equity), or null.
  MoneyAccount? bank(AccountProvider provider);
}

/// The signed-in user's accounts, live, plus how SMS map onto them.
class AccountStore extends ChangeNotifier implements AccountResolver {
  AccountStore(this._repository) {
    _sub = _repository.watchAll().listen(
      (list) {
        _accounts = List.unmodifiable(list
          ..sort((a, b) => a.order != b.order
              ? a.order.compareTo(b.order)
              : a.name.compareTo(b.name)));
        _loaded = true;
        notifyListeners();
      },
      onError: (Object e) {
        _loaded = true;
        debugPrint('Accounts unavailable: $e');
        notifyListeners();
      },
    );
  }

  final AccountRepository _repository;
  late final StreamSubscription<List<MoneyAccount>> _sub;
  List<MoneyAccount> _accounts = const [];
  bool _loaded = false;

  bool get isLoaded => _loaded;
  List<MoneyAccount> get all => _accounts;
  List<MoneyAccount> get active => _accounts.where((a) => a.active).toList();

  MoneyAccount? byId(String? id) {
    if (id == null) return null;
    for (final a in _accounts) {
      if (a.id == id) return a;
    }
    return null;
  }

  @override
  MoneyAccount? firstOf(AccountKind kind, {bool includeHidden = false}) {
    for (final a in _accounts) {
      if ((a.active || includeHidden) && a.kind == kind && a.simSlot == null) {
        return a;
      }
    }
    return null;
  }

  @override
  MoneyAccount? bank(AccountProvider provider) {
    for (final a in _accounts) {
      if (a.active && a.kind == AccountKind.bank && a.provider == provider) {
        return a;
      }
    }
    return null;
  }

  @override
  MoneyAccount? forSim(int? slot, AccountKind kind,
      {AccountProvider provider = AccountProvider.safaricom}) {
    if (slot == null) return null;
    for (final a in _accounts) {
      if (a.active &&
          a.kind == kind &&
          a.simSlot == slot &&
          a.provider == provider) {
        return a;
      }
    }
    return null;
  }

  Future<void> save(MoneyAccount a) => _repository.save(a);

  /// See [AccountRepository.anchorHistory] and [AnchorKeeper].
  Future<List<AnchorChange>> anchorHistory() => _repository.anchorHistory();
  Future<bool> saveWithAnchor(MoneyAccount a, AnchorChange c) =>
      _repository.saveWithAnchor(a, c);
  Future<bool> undoAnchor(MoneyAccount a, AnchorChange c) =>
      _repository.undoAnchor(a, c);

  Future<void> createStarterSet() =>
      _repository.createMissing(MoneyAccount.starterSet());

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}
