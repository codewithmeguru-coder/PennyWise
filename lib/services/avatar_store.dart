import 'dart:async';
import 'package:flutter/foundation.dart';

import '../data/avatar_repository.dart';
import '../data/data_exception.dart';
import '../models/avatar_photo.dart';
import 'photo_picker.dart';

/// The signed-in user's own profile photo, kept in step with Firestore.
///
/// One per signed-in user; disposed on sign-out, so another profile never
/// sees it. While loading, or if it can't load, [photo] is null and the
/// avatar shows the Google photo or initials.
class AvatarStore extends ChangeNotifier {
  AvatarStore(this._repository) {
    _sub = _repository.watch().listen(
      (bytes) {
        _photo = bytes;
        _error = null;
        notifyListeners();
      },
      onError: (Object e) {
        _error = DataException.from(e).message;
        notifyListeners();
      },
    );
  }

  final AvatarRepository _repository;
  StreamSubscription<Uint8List?>? _sub;

  Uint8List? _photo;
  Uint8List? get photo => _photo;

  String? _error;

  /// Why the photo couldn't load, if it couldn't.
  String? get error => _error;

  bool _busy = false;
  bool get isBusy => _busy;

  /// Lets the user pick a photo and saves it. Returns a message to show,
  /// or null when there's nothing to say (saved, or cancelled).
  Future<String?> change(PhotoPicker picker) =>
      _run(() async => _save(await picker.pick()));

  /// Saves a photo picked just before Android closed the app, if any.
  Future<String?> recover(PhotoPicker picker) =>
      _run(() async => _save(await picker.recoverLost()));

  Future<String?> remove() => _run(() async {
    await _repository.remove();
    return null;
  });

  Future<String?> _save(Uint8List? bytes) async {
    if (bytes == null) return null; // cancelled, or nothing to recover
    if (AvatarPhoto.problemWith(bytes) case final problem?) return problem;
    await _repository.save(bytes);
    return null;
  }

  Future<String?> _run(Future<String?> Function() action) async {
    if (_busy) return null;
    _busy = true;
    notifyListeners();
    try {
      return await action();
    } on PhotoPickerException catch (e) {
      return e.message;
    } on DataException catch (e) {
      return e.message;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
