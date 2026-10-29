import 'dart:async';
import 'dart:typed_data';

import 'package:pennywise/data/avatar_repository.dart';
import 'package:pennywise/data/data_exception.dart';
import 'package:pennywise/services/photo_picker.dart';

/// In-memory [AvatarRepository] so widget tests don't need Firestore.
class FakeAvatarRepository implements AvatarRepository {
  FakeAvatarRepository([this._photo]);

  Uint8List? _photo;
  Uint8List? get photo => _photo;
  final _controller = StreamController<void>.broadcast();

  /// When set, [watch] fails with this.
  DataException? loadError;

  /// When set, the next [save] or [remove] fails with this.
  DataException? writeError;

  /// Every write, in order: "save N" (N bytes) or "remove".
  final writes = <String>[];

  @override
  Stream<Uint8List?> watch() async* {
    if (loadError != null) throw loadError!;
    yield _photo;
    yield* _controller.stream.map((_) => _photo);
  }

  @override
  Future<void> save(Uint8List bytes) async {
    if (writeError case final e?) {
      writeError = null;
      throw e;
    }
    writes.add('save ${bytes.length}');
    _photo = bytes;
    _controller.add(null);
  }

  @override
  Future<void> remove() async {
    if (writeError case final e?) {
      writeError = null;
      throw e;
    }
    writes.add('remove');
    _photo = null;
    _controller.add(null);
  }
}

/// A [PhotoPicker] that returns whatever the test sets.
class FakePhotoPicker implements PhotoPicker {
  /// What [pick] returns (null: the user cancelled).
  Uint8List? next;

  /// When set, [pick] throws it.
  PhotoPickerException? error;

  /// What [recoverLost] returns once.
  Uint8List? lost;

  int picks = 0;

  @override
  Future<Uint8List?> pick() async {
    picks++;
    if (error case final e?) throw e;
    return next;
  }

  @override
  Future<Uint8List?> recoverLost() async {
    final l = lost;
    lost = null;
    return l;
  }
}
