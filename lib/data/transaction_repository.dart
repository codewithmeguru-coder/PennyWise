import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../models/transaction_model.dart';
import 'data_exception.dart';

/// Create / read / update / delete for one user's transactions.
abstract class TransactionRepository {
  /// All of the user's transactions, newest first. Emits again on every
  /// change (including the user's own writes, immediately, from the cache).
  Stream<List<TransactionModel>> watchAll();

  /// Saves a new transaction and returns its generated id.
  Future<String> add(TransactionModel transaction);

  /// Saves a transaction detected from an SMS, unless one with the same
  /// [dedupeKey] was saved before. Returns true if it was added, false if it
  /// was a duplicate.
  ///
  /// [dedupeKey] must be unique per real-world transaction, e.g.
  /// "mpesa_SJK3ABC123" (source + transaction code). Processing the same SMS
  /// twice therefore can never create two transactions.
  Future<bool> addDetected(TransactionModel transaction,
      {required String dedupeKey});

  Future<void> update(TransactionModel transaction);

  Future<void> delete(String id);
}

/// [TransactionRepository] backed by `users/{uid}/transactions` in Firestore.
///
/// The repository is bound to one [uid], so it can only ever touch that
/// user's documents; the security rules enforce the same thing server-side.
class FirestoreTransactionRepository implements TransactionRepository {
  FirestoreTransactionRepository({
    required String uid,
    FirebaseFirestore? firestore,
  }) : _collection = (firestore ?? FirebaseFirestore.instance)
            .collection('users')
            .doc(uid)
            .collection('transactions');

  final CollectionReference<Map<String, dynamic>> _collection;

  @override
  Stream<List<TransactionModel>> watchAll() => _collection
      .orderBy('date', descending: true)
      .snapshots()
      .map((snapshot) => snapshot.docs
          .map(_fromDoc)
          .whereType<TransactionModel>()
          .toList())
      .handleError((Object e) => throw DataException.from(e));

  @override
  Future<String> add(TransactionModel transaction) async {
    final doc = _collection.doc(); // id generated client-side
    await _guard(() => doc.set({
          ..._fields(transaction),
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        }));
    return doc.id;
  }

  @override
  Future<bool> addDetected(TransactionModel transaction,
      {required String dedupeKey}) async {
    // The dedupe key *is* the document id, so there can only ever be one
    // document per transaction code. The Firestore transaction reads it from
    // the server first, and only creates it if it doesn't exist yet.
    final doc = _collection.doc(dedupeKey);
    try {
      return await _collection.firestore.runTransaction((tx) async {
        final existing = await tx.get(doc);
        if (existing.exists) return false;
        tx.set(doc, {
          ..._fields(transaction),
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
        return true;
      });
    } catch (e) {
      throw DataException.from(e);
    }
  }

  @override
  Future<void> update(TransactionModel transaction) {
    final fields = _fields(transaction);
    return _guard(() => _collection.doc(transaction.id).update({
          ...fields,
          // update() merges, so clearing an optional field needs an explicit
          // delete (e.g. a transfer edited into an expense drops toAccount).
          for (final field in _optionalFields)
            if (!fields.containsKey(field)) field: FieldValue.delete(),
          'updatedAt': FieldValue.serverTimestamp(),
        }));
  }

  @override
  Future<void> delete(String id) => _guard(() => _collection.doc(id).delete());

  /// Fields the user can clear by editing; see [update].
  static const _optionalFields = [
    'note', 'account', 'toAccount', 'fee', 'interest', 'refundOf',
  ];

  /// The user-editable fields, in their Firestore types.
  ///
  /// Optional fields are left out when empty, so an income or expense
  /// without an account is written exactly like before accounts existed.
  static Map<String, dynamic> _fields(TransactionModel t) => {
        'amount': t.amount, // number (double)
        'type': t.type.wireName, // e.g. "expense", "savings_contribution"
        'category': t.categoryId,
        'description': t.description,
        if (t.note != null) 'note': t.note,
        'date': Timestamp.fromDate(t.date),
        if (t.account != null) 'account': t.account!.wireName,
        if (t.type == TransactionType.transfer && t.toAccount != null)
          'toAccount': t.toAccount!.wireName,
        if (t.fee != null && t.fee! > 0) 'fee': t.fee,
        if (t.type == TransactionType.debtRepayment && t.interest != null)
          'interest': t.interest,
        if (t.type == TransactionType.refund && t.refundOf != null)
          'refundOf': t.refundOf,
        // Only detected transactions carry these. Manual ones leave them out,
        // so documents written before this feature existed stay unchanged.
        if (t.isDetected) 'source': t.source.name, // "mpesa" | "airtel"
        if (t.reference != null) 'reference': t.reference,
        if (t.smsText != null) 'smsText': t.smsText,
      };

  /// Parses a document, or returns null (and skips it) if it's malformed.
  static TransactionModel? _fromDoc(
      QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    try {
      final data = doc.data();
      final type = TransactionType.fromWire(data['type'] as String?);
      if (type == null) {
        // Written by a newer version of the app; skip rather than misread.
        debugPrint('Skipping transaction ${doc.id} of unknown type');
        return null;
      }
      return TransactionModel(
        id: doc.id,
        description: data['description'] as String,
        amount: (data['amount'] as num).toDouble(),
        type: type,
        categoryId: data['category'] as String,
        date: (data['date'] as Timestamp).toDate(),
        note: data['note'] as String?,
        // Missing on manual entries (and on everything saved before SMS
        // detection existed): those are manual.
        source: TransactionSource.values.asNameMap()[data['source']] ??
            TransactionSource.manual,
        reference: data['reference'] as String?,
        smsText: data['smsText'] as String?,
        // All missing on documents saved before accounts existed.
        account: Account.fromWire(data['account'] as String?),
        toAccount: Account.fromWire(data['toAccount'] as String?),
        fee: (data['fee'] as num?)?.toDouble(),
        interest: (data['interest'] as num?)?.toDouble(),
        refundOf: data['refundOf'] as String?,
      );
    } catch (e) {
      debugPrint('Skipping malformed transaction ${doc.id}: $e');
      return null;
    }
  }

  static Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      throw DataException.from(e);
    }
  }
}
