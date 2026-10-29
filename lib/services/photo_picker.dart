import 'package:flutter/services.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import '../models/avatar_photo.dart';

/// Thrown when the picker itself failed (not when the user cancelled).
class PhotoPickerException implements Exception {
  const PhotoPickerException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Lets the user choose one photo from the gallery, already shrunk.
abstract class PhotoPicker {
  /// The chosen photo's bytes, or null if the user cancelled.
  Future<Uint8List?> pick();

  /// A photo chosen just before Android closed the app (low memory), or
  /// null when there is none.
  Future<Uint8List?> recoverLost();
}

/// [PhotoPicker] over the official Android image picker. Gallery only, so no
/// camera permission; the system Photo Picker is used (Android 13+, and on
/// older versions where it's available), which needs no storage permission
/// and only hands over the photo chosen. The photo is resized to at most
/// [AvatarPhoto.maxSide] and compressed to [AvatarPhoto.quality] on the
/// phone; JPEG, PNG and WebP keep their format.
class AndroidPhotoPicker implements PhotoPicker {
  AndroidPhotoPicker({ImagePickerPlatform? platform})
    : _platform = platform ?? ImagePickerPlatform.instance {
    if (_platform case final ImagePickerAndroid android) {
      android.useAndroidPhotoPicker = true;
    }
  }

  final ImagePickerPlatform _platform;

  static const options = ImagePickerOptions(
    maxWidth: AvatarPhoto.maxSide,
    maxHeight: AvatarPhoto.maxSide,
    imageQuality: AvatarPhoto.quality,
    // No location or other metadata is needed for a profile photo.
    requestFullMetadata: false,
  );

  @override
  Future<Uint8List?> pick() async {
    try {
      final file = await _platform.getImageFromSource(
        source: ImageSource.gallery,
        options: options,
      );
      return file == null ? null : await file.readAsBytes();
    } on PlatformException catch (e) {
      throw PhotoPickerException(
        'Couldn\'t open your photos (${e.code}). Please try again.',
      );
    }
  }

  @override
  Future<Uint8List?> recoverLost() async {
    final LostDataResponse lost;
    try {
      lost = await _platform.getLostData();
    } on UnimplementedError {
      return null;
    }
    if (lost.isEmpty) return null;
    if (lost.exception != null) {
      throw const PhotoPickerException(
        'The photo you chose earlier couldn\'t be recovered. Please choose '
        'it again.',
      );
    }
    final file = lost.file ?? lost.files?.firstOrNull;
    return file == null ? null : await file.readAsBytes();
  }
}
