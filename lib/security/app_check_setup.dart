import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';

/// Firebase App Check: lets Firestore and Authentication tell requests from
/// the genuine PennyWise app apart from scripts that only have the public
/// API key.
///
/// - Release (and profile) builds use **Play Integrity**.
/// - Debug builds use the **debug provider**. It is chosen by [kDebugMode],
///   which is a compile-time constant, so a release build can never select
///   it. No debug token is built in: on first run Firebase logs one, which a
///   developer registers in Firebase Console › App Check › Manage debug
///   tokens.
///
/// Enforcement is switched on separately in the Firebase Console. Until
/// then, requests without a valid token are still allowed, and App Check
/// only reports them in its metrics.
class AppCheckSetup {
  AppCheckSetup._();

  /// The Android provider for a build: debug builds only get the debug
  /// provider.
  @visibleForTesting
  static AndroidAppCheckProvider providerFor({required bool debugBuild}) =>
      debugBuild
      ? const AndroidDebugProvider()
      : const AndroidPlayIntegrityProvider();

  /// The provider this build uses.
  static AndroidAppCheckProvider get androidProvider =>
      providerFor(debugBuild: kDebugMode);

  /// Starts App Check. Call right after `Firebase.initializeApp` and before
  /// any Firebase service is used. A failure is logged and the app carries
  /// on: while enforcement is off, nothing depends on it.
  static Future<void> activate() async {
    try {
      await FirebaseAppCheck.instance.activate(
        providerAndroid: androidProvider,
      );
    } catch (e) {
      debugPrint('App Check could not start: $e');
    }
  }
}
