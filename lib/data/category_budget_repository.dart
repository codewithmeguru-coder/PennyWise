import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/budget_model.dart';
import '../models/category_budget.dart';
import 'data_exception.dart';
import 'write_limit.dart';

/// Read / write one user's per-category monthly limits.
abstract class CategoryBudgetRepository {
  /// The month's limits by category id; empty when none are set. Emits on
  /// every change.
  Stream<Map<String, double>> watchMonth(DateTime month);

  /// Creates or replaces the limit for [CategoryBudget.categoryId] in
  /// [CategoryBudget.month].
  Future<void> save(CategoryBudget budget);

  /// Removes one category's limit for [month]; nothing else.
  Future<void> delete(DateTime month, String categoryId);
}

/// [CategoryBudgetRepository] backed by
/// `users/{uid}/categoryBudgets/{YYYY-MM}_{categoryId}` in Firestore.
class FirestoreCategoryBudgetRepository implements CategoryBudgetRepository {
  FirestoreCategoryBudgetRepository({required this._uid, this._firestore});

  final String _uid;
  final FirebaseFirestore? _firestore;

  // Created on first use, so building the app (or a test) never needs
  // Firebase until limits are actually read or written.
  late final CollectionReference<Map<String, dynamic>> _collection =
      (_firestore ?? FirebaseFirestore.instance)
          .collection('users')
          .doc(_uid)
          .collection('categoryBudgets');

  @override
  Stream<Map<String, double>> watchMonth(DateTime month) => _collection
      .where('month', isEqualTo: BudgetModel.idFor(month))
      .snapshots()
      .map(
        (query) => {
          for (final doc in query.docs)
            if (doc.data()['categoryId'] case final String id)
              if (doc.data()['limit'] case final num limit)
                id: limit.toDouble(),
        },
      )
      .handleError((Object e) => throw DataException.from(e));

  @override
  Future<void> save(CategoryBudget budget) async {
    final doc = _collection.doc(budget.id);
    try {
      // Each save claims one from today's edit limit, in the same write.
      await _collection.firestore.runTransaction((tx) async {
        await WriteLimit.claimEdit(
          tx,
          WriteLimit.editCounterOf(_collection),
          'categoryBudgets/${doc.id}',
        );
        tx.set(doc, {
          'month': budget.monthId, // "YYYY-MM"
          'categoryId': budget.categoryId, // e.g. "food"
          'limit': budget.limit, // number
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });
    } on DataException {
      rethrow;
    } catch (e) {
      throw DataException.from(e);
    }
  }

  @override
  Future<void> delete(DateTime month, String categoryId) async {
    try {
      await _collection.doc(CategoryBudget.idFor(month, categoryId)).delete();
    } catch (e) {
      throw DataException.from(e);
    }
  }
}
