import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/custom_category.dart';
import '../models/transaction_model.dart';
import 'data_exception.dart';

/// Read / write one user's own categories. There is no delete: a category
/// is deactivated instead, so past records always find it.
abstract class CategoryRepository {
  /// Every custom category, active and inactive. Emits on every change.
  Stream<List<CustomCategory>> watchAll();

  /// Saves a new category. Fails with a [DataException] if the id is taken.
  Future<void> create(CustomCategory category);

  /// Saves a new name, icon or active flag. The id and type never change.
  Future<void> update(CustomCategory category);
}

/// [CategoryRepository] backed by `users/{uid}/categories/{id}`.
class FirestoreCategoryRepository implements CategoryRepository {
  FirestoreCategoryRepository({required this._uid, this._firestore});

  final String _uid;
  final FirebaseFirestore? _firestore;

  // Created on first use, so building the app (or a test) never needs
  // Firebase until categories are actually read or written.
  late final FirebaseFirestore _db = _firestore ?? FirebaseFirestore.instance;
  late final CollectionReference<Map<String, dynamic>> _collection = _db
      .collection('users')
      .doc(_uid)
      .collection('categories');

  static CustomCategory? _fromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final d = doc.data();
    final type = TransactionType.fromWire(d['type'] as String?);
    final name = d['name'];
    if (name is! String ||
        (type != TransactionType.expense && type != TransactionType.income)) {
      return null; // not something this version can show
    }
    return CustomCategory(
      id: doc.id,
      name: name,
      type: type!,
      icon: d['icon'] is String ? d['icon'] as String : 'label',
      active: d['active'] != false,
    );
  }

  @override
  Stream<List<CustomCategory>> watchAll() => _collection
      .snapshots()
      .map(
        (q) => [
          for (final doc in q.docs)
            ?_fromDoc(doc),
        ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase())),
      )
      .handleError((Object e) => throw DataException.from(e));

  @override
  Future<void> create(CustomCategory category) async {
    final ref = _collection.doc(category.id);
    try {
      await _db.runTransaction((tx) async {
        if ((await tx.get(ref)).exists) {
          throw const DataException('That category id is taken. Try again.');
        }
        tx.set(ref, {
          'name': category.name,
          'type': category.type.wireName,
          'icon': category.icon,
          'active': category.active,
          'createdAt': FieldValue.serverTimestamp(),
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
  Future<void> update(CustomCategory category) async {
    try {
      await _collection.doc(category.id).update({
        'name': category.name,
        'icon': category.icon,
        'active': category.active,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      throw DataException.from(e);
    }
  }
}
