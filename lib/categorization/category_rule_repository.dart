import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../data/data_exception.dart';
import '../models/transaction_model.dart';
import 'category_rule.dart';

/// Read / write one user's learned category rules.
abstract class CategoryRuleRepository {
  /// All rules; emits again on every change.
  Stream<List<CategoryRule>> watchAll();

  /// Creates the rule, or updates its category and adds one to its count.
  Future<void> remember(CategoryRule rule);

  Future<void> delete(String key);
}

/// [CategoryRuleRepository] backed by `users/{uid}/categoryRules`.
class FirestoreCategoryRuleRepository implements CategoryRuleRepository {
  FirestoreCategoryRuleRepository({
    required String uid,
    FirebaseFirestore? firestore,
  }) : _collection = (firestore ?? FirebaseFirestore.instance)
            .collection('users')
            .doc(uid)
            .collection('categoryRules');

  final CollectionReference<Map<String, dynamic>> _collection;

  @override
  Stream<List<CategoryRule>> watchAll() => _collection
      .snapshots()
      .map((s) => s.docs.map(_fromDoc).whereType<CategoryRule>().toList())
      .handleError((Object e) => throw DataException.from(e));

  @override
  Future<void> remember(CategoryRule rule) async {
    final doc = _collection.doc(rule.key);
    try {
      await _collection.firestore.runTransaction((tx) async {
        final existing = await tx.get(doc);
        final fields = {
          'merchantKey': rule.key,
          'categoryId': rule.categoryId,
          'type': rule.type.wireName,
          if (rule.label != null) 'label': rule.label,
          'updatedAt': FieldValue.serverTimestamp(),
        };
        if (existing.exists) {
          final count = (existing.data()?['count'] as int? ?? 0) + 1;
          tx.update(doc, {...fields, 'count': count});
        } else {
          tx.set(doc, {
            ...fields,
            'count': 1,
            'createdAt': FieldValue.serverTimestamp(),
          });
        }
      });
    } catch (e) {
      throw DataException.from(e);
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _collection.doc(key).delete();
    } catch (e) {
      throw DataException.from(e);
    }
  }

  static CategoryRule? _fromDoc(
      QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    try {
      final data = doc.data();
      final type = TransactionType.fromWire(data['type'] as String?);
      if (type == null) return null;
      return CategoryRule(
        key: doc.id,
        categoryId: data['categoryId'] as String,
        type: type,
        count: data['count'] as int? ?? 1,
        label: data['label'] as String?,
      );
    } catch (e) {
      debugPrint('Skipping malformed category rule ${doc.id}');
      return null;
    }
  }
}

/// The signed-in user's learned rules, kept in memory and updated live.
/// One small listener per session; no reads per transaction.
class CategoryRuleStore extends ChangeNotifier {
  CategoryRuleStore(this._repository) {
    _subscription = _repository.watchAll().listen(
      (rules) {
        _rules = {for (final r in rules) r.key: r};
        notifyListeners();
      },
      onError: (Object e) => debugPrint('Category rules unavailable: $e'),
    );
  }

  final CategoryRuleRepository _repository;
  late final StreamSubscription<List<CategoryRule>> _subscription;
  Map<String, CategoryRule> _rules = const {};

  Map<String, CategoryRule> get rules => _rules;

  List<CategoryRule> get sorted => _rules.values.toList()
    ..sort((a, b) => (a.label ?? a.key).compareTo(b.label ?? b.key));

  Future<void> remember(CategoryRule rule) => _repository.remember(rule);

  Future<void> forget(String key) => _repository.delete(key);

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}
