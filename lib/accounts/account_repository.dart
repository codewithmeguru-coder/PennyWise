import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../data/data_exception.dart';
import 'money_account.dart';

/// Read / write one user's accounts (`users/{uid}/accounts`).
abstract class AccountRepository {
  Stream<List<MoneyAccount>> watchAll();

  /// Creates or replaces [account] (its id is the document id).
  Future<void> save(MoneyAccount account);

  /// Creates every account in [accounts] that doesn't exist yet.
  Future<void> createMissing(List<MoneyAccount> accounts);
}

class FirestoreAccountRepository implements AccountRepository {
  FirestoreAccountRepository({required String uid, FirebaseFirestore? firestore})
      : _collection = (firestore ?? FirebaseFirestore.instance)
            .collection('users')
            .doc(uid)
            .collection('accounts');

  final CollectionReference<Map<String, dynamic>> _collection;

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
        'updatedAt': FieldValue.serverTimestamp(),
      };

  @override
  Future<void> save(MoneyAccount account) async {
    final doc = _collection.doc(account.id);
    try {
      await _collection.firestore.runTransaction((tx) async {
        final existing = await tx.get(doc);
        if (existing.exists) {
          tx.update(doc, {
            ..._fields(account),
            // update() merges: clear optional fields the user removed.
            if (account.openingBalance == null)
              'openingBalance': FieldValue.delete(),
            if (account.openingDate == null) 'openingDate': FieldValue.delete(),
          });
        } else {
          tx.set(doc, {
            ..._fields(account),
            'createdAt': FieldValue.serverTimestamp(),
          });
        }
      });
    } catch (e) {
      throw DataException.from(e);
    }
  }

  @override
  Future<void> createMissing(List<MoneyAccount> accounts) async {
    try {
      await _collection.firestore.runTransaction((tx) async {
        final docs = [for (final a in accounts) _collection.doc(a.id)];
        final existing = [for (final d in docs) await tx.get(d)];
        for (var i = 0; i < accounts.length; i++) {
          if (existing[i].exists) continue;
          tx.set(docs[i], {
            ..._fields(accounts[i]),
            'createdAt': FieldValue.serverTimestamp(),
          });
        }
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

  Future<void> createStarterSet() =>
      _repository.createMissing(MoneyAccount.starterSet());

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}
