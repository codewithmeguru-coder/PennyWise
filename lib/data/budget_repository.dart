import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/budget_model.dart';
import 'data_exception.dart';

/// Read / write one user's monthly budgets.
abstract class BudgetRepository {
  /// The budget for [month], or null if none is set. Emits on every change.
  Stream<BudgetModel?> watchMonth(DateTime month);

  /// Creates or replaces the budget for [BudgetModel.month].
  Future<void> save(BudgetModel budget);

  Future<void> delete(DateTime month);
}

/// [BudgetRepository] backed by `users/{uid}/budgets/{YYYY-MM}` in Firestore.
class FirestoreBudgetRepository implements BudgetRepository {
  FirestoreBudgetRepository({
    required String uid,
    FirebaseFirestore? firestore,
  }) : _collection = (firestore ?? FirebaseFirestore.instance)
            .collection('users')
            .doc(uid)
            .collection('budgets');

  final CollectionReference<Map<String, dynamic>> _collection;

  @override
  Stream<BudgetModel?> watchMonth(DateTime month) => _collection
      .doc(BudgetModel.idFor(month))
      .snapshots()
      .map((doc) {
        final limit = doc.data()?['limit'];
        return limit is num
            ? BudgetModel(month: month, limit: limit.toDouble())
            : null;
      })
      .handleError((Object e) => throw DataException.from(e));

  @override
  Future<void> save(BudgetModel budget) async {
    try {
      await _collection.doc(budget.monthId).set({
        'month': budget.monthId, // string "YYYY-MM", same as the doc id
        'limit': budget.limit, // number
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      throw DataException.from(e);
    }
  }

  @override
  Future<void> delete(DateTime month) async {
    try {
      await _collection.doc(BudgetModel.idFor(month)).delete();
    } catch (e) {
      throw DataException.from(e);
    }
  }
}
