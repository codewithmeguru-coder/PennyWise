import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/security/pin_hasher.dart';

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('PBKDF2-HMAC-SHA256 (pointycastle) matches RFC 7914 section 11', () {
    test('P="passwd", S="salt", c=1, dkLen=64', () {
      final out =
          PinHasher.pbkdf2(utf8.encode('passwd'), utf8.encode('salt'), 1, 64);
      expect(
          hex(out),
          '55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc'
          '49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783');
    });

    test('P="Password", S="NaCl", c=80000, dkLen=64', () {
      final out = PinHasher.pbkdf2(
          utf8.encode('Password'), utf8.encode('NaCl'), 80000, 64);
      expect(
          hex(out),
          '4ddcd8f60b98be21830cee5ef22701f9641a4418d04c0414aeff08876b34ab56'
          'a1d425a1225833549adb841b51c9b3176a272bdebba1d078478f62b397f33c8d');
    });
  });

  group('PinHasher', () {
    const hasher = PinHasher(iterations: 1000, runInBackground: false);

    test('accepts the right PIN and rejects others', () async {
      final stored = await hasher.hash('2468');
      expect(await hasher.verify('2468', stored), isTrue);
      expect(await hasher.verify('2469', stored), isFalse);
      expect(await hasher.verify('24680', stored), isFalse);
    });

    test('never stores the PIN; every hash gets its own random salt',
        () async {
      final a = await hasher.hash('2468');
      final b = await hasher.hash('2468');

      expect(a.salt, hasLength(PinHasher.saltLength));
      expect(a.hash, hasLength(PinHasher.keyLength));
      expect(hex(a.salt), isNot(hex(b.salt)));
      expect(hex(a.hash), isNot(hex(b.hash)));
      expect(jsonEncode(a.toJson()), isNot(contains('2468')));
    });

    test('keeps working after a round-trip through storage', () async {
      final stored = await hasher.hash('135790');
      final restored =
          PinHash.fromJson(jsonDecode(jsonEncode(stored.toJson())));
      expect(await hasher.verify('135790', restored), isTrue);
      expect(restored.iterations, 1000);
    });

    test('uses the iteration count saved with the hash', () async {
      final stored = await hasher.hash('1111');
      const stronger = PinHasher(iterations: 5000, runInBackground: false);
      expect(await stronger.verify('1111', stored), isTrue);
    });

    test('the default runs on a background isolate', () async {
      const background = PinHasher(iterations: 1000);
      final stored = await background.hash('8642');
      expect(await background.verify('8642', stored), isTrue);
    });

    test('valid PINs are 4 to 6 digits', () {
      expect(PinHasher.isValidPin('123'), isFalse);
      expect(PinHasher.isValidPin('1234'), isTrue);
      expect(PinHasher.isValidPin('123456'), isTrue);
      expect(PinHasher.isValidPin('1234567'), isFalse);
      expect(PinHasher.isValidPin('12a4'), isFalse);
    });

    test('constant-time compare', () {
      expect(PinHasher.constantTimeEquals([1, 2, 3], [1, 2, 3]), isTrue);
      expect(PinHasher.constantTimeEquals([1, 2, 3], [1, 2, 4]), isFalse);
      expect(PinHasher.constantTimeEquals([1, 2], [1, 2, 3]), isFalse);
    });

    test('calibration picks rounds for about 300 ms on this machine', () {
      final rounds = PinHasher.calibrate();
      expect(rounds,
          inInclusiveRange(PinHasher.minIterations, PinHasher.maxIterations));
      final watch = Stopwatch()..start();
      PinHasher.pbkdf2(utf8.encode('1234'), List.filled(16, 7), rounds,
          PinHasher.keyLength);
      // ignore: avoid_print
      print('calibrated: $rounds rounds, ${watch.elapsedMilliseconds} ms');
    });

    test('an uncalibrated hasher stores the measured round count', () async {
      const adaptive = PinHasher(runInBackground: false);
      final stored = await adaptive.hash('5555');
      expect(stored.iterations, greaterThanOrEqualTo(PinHasher.minIterations));
      expect(await adaptive.verify('5555', stored), isTrue);
    });
  });
}
