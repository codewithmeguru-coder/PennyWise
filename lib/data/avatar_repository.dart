import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/avatar_photo.dart';
import 'data_exception.dart';

/// Read / write the signed-in user's own profile photo.
abstract class AvatarRepository {
  /// The photo, or null when none is set. Emits on every change.
  Stream<Uint8List?> watch();

  /// Saves [bytes] (already checked with [AvatarPhoto.problemWith]),
  /// replacing any earlier photo.
  Future<void> save(Uint8List bytes);

  /// Removes the photo; the Google photo or initials show again.
  Future<void> remove();
}

/// [AvatarRepository] backed by the single document
/// `users/{uid}/private/avatar` (`imageBase64`, `updatedAt`). No Firebase
/// Storage: a 256 px photo is small enough for one document.
class FirestoreAvatarRepository implements AvatarRepository {
  FirestoreAvatarRepository({required this._uid, this._firestore});

  final String _uid;
  final FirebaseFirestore? _firestore;

  // Created on first use, so building the app (or a test) never needs
  // Firebase until the photo is actually read or written.
  late final DocumentReference<Map<String, dynamic>> _doc =
      (_firestore ?? FirebaseFirestore.instance)
          .collection('users')
          .doc(_uid)
          .collection('private')
          .doc('avatar');

  @override
  Stream<Uint8List?> watch() => _doc
      .snapshots()
      .map((d) => AvatarPhoto.decode(d.data()?['imageBase64']))
      .handleError((Object e) => throw DataException.from(e));

  @override
  Future<void> save(Uint8List bytes) async {
    try {
      await _doc.set({
        'imageBase64': AvatarPhoto.encode(bytes),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      throw DataException.from(e);
    }
  }

  @override
  Future<void> remove() async {
    try {
      await _doc.delete();
    } catch (e) {
      throw DataException.from(e);
    }
  }
}
