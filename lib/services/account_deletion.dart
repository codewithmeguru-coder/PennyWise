import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/data_exception.dart';
import 'auth_service.dart';

/// Everything stored for one user, and removing it. Only ever the signed-in
/// user's own `users/{uid}` tree: the Firestore rules allow nothing else.
abstract class UserDataStore {
  /// A deletion was started and hasn't finished (its request record exists).
  Future<bool> deletionPending();

  /// Records the deletion request first. While it exists the rules let the
  /// owner delete the records that are otherwise kept (accounts, balance
  /// history, categories).
  Future<void> markDeletion();

  /// Deletes up to [batch] documents of [collection]; returns how many (0
  /// when it is empty).
  Future<int> deleteSome(String collection, {int batch});

  /// Deletes one document by path under the user (e.g. "private/avatar").
  Future<void> deleteDoc(String path);

  /// Removes the request record (last, after everything it unlocked).
  Future<void> clearMarker();

  /// Deletes the `users/{uid}` profile.
  Future<void> deleteProfile();
}

class FirestoreUserDataStore implements UserDataStore {
  FirestoreUserDataStore({required this.uid, this._firestore});

  final String uid;
  final FirebaseFirestore? _firestore;

  // Resolved on first use, so creating this touches nothing.
  late final DocumentReference<Map<String, dynamic>> _user =
      (_firestore ?? FirebaseFirestore.instance).collection('users').doc(uid);
  DocumentReference<Map<String, dynamic>> get _marker =>
      _user.collection('deletionRequest').doc('current');

  Future<T> _guard<T>(Future<T> Function() f) async {
    try {
      return await f();
    } catch (e) {
      throw DataException.from(e);
    }
  }

  @override
  Future<bool> deletionPending() =>
      _guard(() async => (await _marker.get()).exists);

  @override
  Future<void> markDeletion() => _guard(
    () => _marker.set({'requestedAt': FieldValue.serverTimestamp()}),
  );

  @override
  Future<int> deleteSome(String collection, {int batch = 200}) =>
      _guard(() async {
        final snap = await _user.collection(collection).limit(batch).get();
        if (snap.docs.isEmpty) return 0;
        final write = _user.firestore.batch();
        for (final d in snap.docs) {
          write.delete(d.reference);
        }
        await write.commit();
        return snap.docs.length;
      });

  @override
  Future<void> deleteDoc(String path) => _guard(() {
    final [collection, id] = path.split('/');
    return _user.collection(collection).doc(id).delete();
  });

  @override
  Future<void> clearMarker() => _guard(() => _marker.delete());

  @override
  Future<void> deleteProfile() => _guard(() => _user.delete());
}

/// Settings and records kept on this phone for one user (detection state,
/// handled message codes, repair-tool safety copies): every saved key that
/// names their uid.
class LocalUserData {
  LocalUserData._();

  static Future<int> clear(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    final keys = [
      for (final k in prefs.getKeys())
        if (k.contains(uid)) k,
    ];
    for (final k in keys) {
      await prefs.remove(k);
    }
    return keys.length;
  }
}

/// Where a deletion stopped, for a message the user can act on.
class DeletionException implements Exception {
  const DeletionException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Deletes the signed-in user's whole account: every record they own, the
/// settings this phone keeps for them, and finally their sign-in.
///
/// Call [run] only right after [AuthService.reauthenticate] succeeded.
/// Safe to repeat: the request record is written first and removed only
/// after all the data is gone, so a deletion that stops halfway (no
/// connection, app closed) is finished by running it again; deleting what
/// is already gone does nothing.
class AccountDeletion {
  AccountDeletion({
    required this._data,
    required this._auth,
    required this._clearLocal,
  });

  final UserDataStore _data;
  final AuthService _auth;

  /// For confirming it's the owner just before [run].
  AuthService get auth => _auth;
  final Future<void> Function() _clearLocal;

  /// Every collection under users/{uid}, in the order they're removed.
  static const collections = [
    'transactions',
    'categoryRules',
    'budgets',
    'categoryBudgets',
    'balanceAnchors',
    'accounts',
    'categories',
  ];

  /// The profile photo (the only document under private/).
  static const photo = 'private/avatar';

  Future<bool> pending() async {
    try {
      return await _data.deletionPending();
    } catch (_) {
      return false;
    }
  }

  Future<void> run({void Function(String step)? onStep}) async {
    void step(String s) => onStep?.call(s);
    try {
      step('Recording the request');
      await _data.markDeletion();
      for (final c in collections) {
        step('Deleting ${_label(c)}');
        while (await _data.deleteSome(c) > 0) {}
      }
      step('Deleting your profile photo');
      await _data.deleteDoc(photo);
      await _data.clearMarker();
      step('Deleting your profile');
      await _data.deleteProfile();
    } on DataException catch (e) {
      throw DeletionException(
        "Deletion stopped: ${e.message} Nothing is lost by trying again; "
        "it continues where it stopped.",
      );
    }
    step('Clearing this phone');
    await _clearLocal();
    step('Deleting your sign-in');
    try {
      await _auth.deleteSignIn();
    } on AuthException catch (e) {
      throw DeletionException(
        'Your data is deleted, but your sign-in could not be: ${e.message}',
      );
    }
  }

  static String _label(String c) => switch (c) {
    'transactions' => 'transactions',
    'categoryRules' => 'learned categories',
    'budgets' => 'budgets',
    'categoryBudgets' => 'category limits',
    'balanceAnchors' => 'balance history',
    'accounts' => 'accounts',
    'categories' => 'your categories',
    _ => c,
  };
}
