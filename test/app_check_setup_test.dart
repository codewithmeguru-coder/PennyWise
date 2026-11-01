import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/security/app_check_setup.dart';

// App Check: Play Integrity for release builds; the debug provider only in
// debug builds, with no debug token built into the app.

void main() {
  test('release builds use Play Integrity', () {
    expect(
      AppCheckSetup.providerFor(debugBuild: false),
      isA<AndroidPlayIntegrityProvider>(),
    );
  });

  test('debug builds use the debug provider, with no built-in token', () {
    final p = AppCheckSetup.providerFor(debugBuild: true);
    expect(p, isA<AndroidDebugProvider>());
    expect((p as AndroidDebugProvider).debugToken, isNull);
  });

  test('the build picks by kDebugMode (tests run as a debug build)', () {
    expect(kDebugMode, isTrue);
    expect(AppCheckSetup.androidProvider, isA<AndroidDebugProvider>());
  });
}
