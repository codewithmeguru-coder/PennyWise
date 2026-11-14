import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'data_exception.dart';

/// The daily limits the Firestore rules enforce (see `claimsLimit` and
/// `claimsEdit` in firestore.rules), each claimed in the same Firestore
/// transaction as the write it counts:
/// - every new transaction, learned category, custom category, account or
///   balance history record claims one write from the owner's counter at
///   `users/{uid}/limits/daily`;
/// - every edit (an update of the profile, a transaction, learned category,
///   account or category, or a save of a budget, category limit or photo)
///   claims one edit from `users/{uid}/limits/edits`.
///
/// Normal use stays far below both; they stop a script (or a bug) from
/// writing without end and using up the project's free quota.
class WriteLimit {
  WriteLimit._();

  /// Must match `dailyWriteLimit()` in firestore.rules.
  static const daily = 1500;

  /// Must match `dailyEditLimit()` in firestore.rules.
  static const edits = 3000;

  static DocumentReference<Map<String, dynamic>> counter(
    FirebaseFirestore db,
    String uid,
  ) => db.collection('users').doc(uid).collection('limits').doc('daily');

  static DocumentReference<Map<String, dynamic>> editCounter(
    FirebaseFirestore db,
    String uid,
  ) => db.collection('users').doc(uid).collection('limits').doc('edits');

  /// The counter of the user that owns [collection] (users/{uid}/...).
  static DocumentReference<Map<String, dynamic>> counterOf(
    CollectionReference<Map<String, dynamic>> collection,
  ) => collection.parent!.collection('limits').doc('daily');

  /// The edit counter of the user that owns [collection].
  static DocumentReference<Map<String, dynamic>> editCounterOf(
    CollectionReference<Map<String, dynamic>> collection,
  ) => collection.parent!.collection('limits').doc('edits');

  /// The count the rules expect next: one more than today's, or 1 on a new
  /// UTC day (or the first time).
  @visibleForTesting
  static int nextCount(Map<String, dynamic>? data, DateTime now) {
    final at = (data?['at'] as Timestamp?)?.toDate().toUtc();
    final count = data?['count'] as int? ?? 0;
    final today = now.toUtc();
    final sameDay = at != null &&
        at.year == today.year &&
        at.month == today.month &&
        at.day == today.day;
    return sameDay ? count + 1 : 1;
  }

  static const reachedMessage =
      'You\'ve added the maximum number of records for today. The rest will '
      'be added tomorrow.';

  static const editsReachedMessage =
      'You\'ve made the maximum number of changes for today. Please try '
      'again tomorrow.';

  /// Claims one write for [path] (e.g. "transactions/mpesa_ABC") inside
  /// [tx]. Call after the transaction's reads and before its writes.
  /// Throws a [DataException] once today's limit is reached.
  static Future<void> claim(
    Transaction tx,
    DocumentReference<Map<String, dynamic>> counter,
    String path,
  ) => _claim(tx, counter, path, daily, reachedMessage);

  /// Claims one edit of [path] (e.g. "transactions/mpesa_ABC", "profile")
  /// inside [tx]: like [claim], from the edit counter.
  static Future<void> claimEdit(
    Transaction tx,
    DocumentReference<Map<String, dynamic>> counter,
    String path,
  ) => _claim(tx, counter, path, edits, editsReachedMessage);

  /// Claims one edit of [editPath] and one new record for [newPath] in the
  /// same [tx] (an account update with its new history record). A
  /// Firestore transaction must do all its reads before any write, so this
  /// reads both counters first; [claim] then [claimEdit] would fail.
  static Future<void> claimEditAndNew(
    Transaction tx, {
    required DocumentReference<Map<String, dynamic>> editCounter,
    required String editPath,
    required DocumentReference<Map<String, dynamic>> counter,
    required String newPath,
  }) async {
    final e = await tx.get(editCounter);
    final d = await tx.get(counter);
    final now = DateTime.now();
    final editFields =
        claimFields(e.data(), now, editPath, edits, editsReachedMessage);
    final newFields = claimFields(d.data(), now, newPath, daily, reachedMessage);
    tx
      ..set(editCounter, editFields)
      ..set(counter, newFields);
  }

  static Future<void> _claim(
    Transaction tx,
    DocumentReference<Map<String, dynamic>> counter,
    String path,
    int limit,
    String message,
  ) async {
    final snap = await tx.get(counter);
    tx.set(
      counter,
      claimFields(snap.data(), DateTime.now(), path, limit, message),
    );
  }

  /// What a claim of [path] writes to a counter holding [data]: one more
  /// than today's count, stamped with the server's time. Throws a
  /// [DataException] with [message] (and nothing is written) once [limit]
  /// is reached today.
  @visibleForTesting
  static Map<String, dynamic> claimFields(
    Map<String, dynamic>? data,
    DateTime now,
    String path,
    int limit,
    String message,
  ) {
    final next = nextCount(data, now);
    if (next > limit) throw DataException(message);
    return {
      'at': FieldValue.serverTimestamp(),
      'count': next,
      'lastPath': path,
    };
  }
}
