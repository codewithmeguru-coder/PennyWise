import 'dart:convert';
import 'dart:typed_data';

/// The image formats a profile photo may be.
enum PhotoFormat { jpeg, png, webp }

/// Checks for a profile photo before it's saved. The Firestore rules check
/// the same things (format and size) on the stored text.
class AvatarPhoto {
  AvatarPhoto._();

  /// Largest photo accepted, in bytes (250 KB).
  static const maxBytes = 250 * 1024;

  /// The longest base64 text for [maxBytes]: what the rules allow.
  static const maxBase64Length = (maxBytes + 2) ~/ 3 * 4;

  /// What the picker is asked for: shrunk on the phone before we see it.
  static const maxSide = 256.0;
  static const quality = 80;

  /// The format from the first bytes ("magic numbers"), or null when it's
  /// none of JPEG, PNG or WebP.
  static PhotoFormat? formatOf(Uint8List bytes) {
    bool starts(List<int> sig, [int at = 0]) {
      if (bytes.length < at + sig.length) return false;
      for (var i = 0; i < sig.length; i++) {
        if (bytes[at + i] != sig[i]) return false;
      }
      return true;
    }

    if (starts([0xFF, 0xD8, 0xFF])) return PhotoFormat.jpeg;
    if (starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
      return PhotoFormat.png;
    }
    if (starts('RIFF'.codeUnits) && starts('WEBP'.codeUnits, 8)) {
      return PhotoFormat.webp;
    }
    return null;
  }

  /// Why [bytes] can't be used as a profile photo, or null when it can.
  static String? problemWith(Uint8List bytes) {
    if (bytes.isEmpty) return 'That photo couldn\'t be read. Try another.';
    if (formatOf(bytes) == null) {
      return 'Choose a JPEG, PNG or WebP photo.';
    }
    if (bytes.length > maxBytes) {
      return 'That photo is too large, even after shrinking. Try another.';
    }
    return null;
  }

  static String encode(Uint8List bytes) => base64Encode(bytes);

  /// The stored text back as bytes; null if it isn't valid.
  static Uint8List? decode(Object? text) {
    if (text is! String || text.isEmpty) return null;
    try {
      final bytes = base64Decode(text);
      return formatOf(bytes) == null ? null : bytes;
    } on FormatException {
      return null;
    }
  }
}
