import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// A stored PIN: never the PIN itself, only what is needed to check one.
class PinHash {
  const PinHash({
    required this.salt,
    required this.hash,
    required this.iterations,
  });

  final Uint8List salt;
  final Uint8List hash;

  /// PBKDF2 rounds used for [hash]; kept so it can be raised later without
  /// breaking existing PINs.
  final int iterations;

  Map<String, Object> toJson() => {
        'salt': base64Encode(salt),
        'hash': base64Encode(hash),
        'iterations': iterations,
      };

  static PinHash fromJson(Map<String, dynamic> json) => PinHash(
        salt: base64Decode(json['salt'] as String),
        hash: base64Decode(json['hash'] as String),
        iterations: json['iterations'] as int,
      );
}

/// Hashes and checks App Lock PINs with PBKDF2-HMAC-SHA256.
///
/// PBKDF2 comes from `pointycastle` (Bouncy Castle): the `crypto` package
/// only has digests and HMAC. Each PIN gets a fresh 16-byte random salt.
/// The work runs on a background isolate so the keypad never freezes.
///
/// The number of rounds is measured on the phone when a PIN is set (see
/// [calibrate]): pure-Dart PBKDF2 is slow, so a fixed high count would make
/// every unlock take seconds. It is saved with the hash.
class PinHasher {
  const PinHasher({
    this.iterations,
    this.runInBackground = true,
  });

  /// Aim for this much work per PIN check on the user's phone.
  static const target = Duration(milliseconds: 300);

  /// Never fewer rounds than this, even on a slow phone.
  static const minIterations = 5000;

  /// Never more than this (OWASP's 2023 figure for PBKDF2-HMAC-SHA256 is
  /// 600,000; pure Dart can't reach that in a usable time on a phone).
  static const maxIterations = 600000;

  static const saltLength = 16;
  static const keyLength = 32;

  /// PINs are 4 to 6 digits.
  static const minLength = 4;
  static const maxLength = 6;

  /// Fixed round count (tests), or null to [calibrate] on this device.
  final int? iterations;

  /// False in tests, where a background isolate doesn't fit fake time.
  final bool runInBackground;

  static bool isValidPin(String pin) =>
      pin.length >= minLength &&
      pin.length <= maxLength &&
      RegExp(r'^\d+$').hasMatch(pin);

  /// PBKDF2-HMAC-SHA256 (RFC 8018), [length] bytes of output.
  static Uint8List pbkdf2(
    List<int> password,
    List<int> salt,
    int iterations,
    int length,
  ) {
    final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(Uint8List.fromList(salt), iterations, length));
    return derivator.process(Uint8List.fromList(password));
  }

  Future<PinHash> hash(String pin) async {
    final random = Random.secure();
    final salt = Uint8List.fromList(
        List.generate(saltLength, (_) => random.nextInt(256)));
    final int rounds;
    if (iterations case final fixed?) {
      rounds = fixed;
    } else {
      rounds = runInBackground ? await Isolate.run(calibrate) : calibrate();
    }
    final hash = await _derive(pin, salt, rounds);
    return PinHash(salt: salt, hash: hash, iterations: rounds);
  }

  /// How many rounds take about [target] on this device, measured with a
  /// short sample run, kept between [minIterations] and [maxIterations].
  static int calibrate() {
    const sample = 2000;
    final watch = Stopwatch()..start();
    pbkdf2(const [0x31, 0x32, 0x33, 0x34], List.filled(saltLength, 0), sample,
        keyLength);
    final micros = max(watch.elapsedMicroseconds, 1);
    final rounds = sample * target.inMicroseconds ~/ micros;
    return rounds.clamp(minIterations, maxIterations);
  }

  Future<bool> verify(String pin, PinHash stored) async {
    final candidate = await _derive(pin, stored.salt, stored.iterations);
    return constantTimeEquals(candidate, stored.hash);
  }

  Future<Uint8List> _derive(String pin, Uint8List salt, int rounds) {
    final bytes = utf8.encode(pin);
    if (!runInBackground) {
      return Future.value(pbkdf2(bytes, salt, rounds, keyLength));
    }
    return Isolate.run(() => pbkdf2(bytes, salt, rounds, keyLength));
  }

  /// Compares every byte, so the time taken doesn't reveal how much of a
  /// wrong hash matched.
  static bool constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
