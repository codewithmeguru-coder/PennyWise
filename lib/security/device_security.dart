import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

/// Talks to MainActivity for the two things Flutter can't do itself.
class DevicePrivacy {
  const DevicePrivacy();

  static const _channel = MethodChannel('pennywise/privacy');

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Hides the app's preview in Android's recent-apps screen (Android 13+).
  /// Screenshots inside the app stay allowed.
  Future<void> hideRecentsPreview(bool hide) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>('hideRecentsPreview', hide);
    } catch (e) {
      debugPrint('Could not change the recent-apps preview setting');
    }
  }

  /// The Android API level, or 0 elsewhere / if unknown.
  Future<int> androidSdk() async {
    if (!_isAndroid) return 0;
    try {
      return await _channel.invokeMethod<int>('sdkInt') ?? 0;
    } catch (_) {
      return 0;
    }
  }
}

/// Fingerprint / face unlock, through the device's own secure prompt.
abstract class BiometricAuth {
  /// True if the device can use biometrics now (hardware present and at
  /// least one fingerprint or face enrolled).
  Future<bool> isAvailable();

  /// Shows the system prompt. True only if the user was recognised.
  Future<bool> authenticate(String reason);
}

/// [BiometricAuth] using `local_auth`. PennyWise never sees or stores any
/// biometric data: Android only answers "recognised" or not.
class LocalBiometricAuth implements BiometricAuth {
  LocalBiometricAuth({LocalAuthentication? auth, DevicePrivacy? device})
      : _auth = auth ?? LocalAuthentication(),
        _device = device ?? const DevicePrivacy();

  final LocalAuthentication _auth;
  final DevicePrivacy _device;

  /// Android 9 and newer. Older versions need an AppCompat theme for the
  /// prompt (which this app doesn't use), so they get the PIN only.
  static const minSdk = 28;

  @override
  Future<bool> isAvailable() async {
    try {
      if (await _device.androidSdk() < minSdk) return false;
      if (!await _auth.canCheckBiometrics) return false;
      return (await _auth.getAvailableBiometrics()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        // Fingerprint / face only: the PIN on our own screen is the fallback,
        // not the phone's screen lock.
        biometricOnly: true,
      );
    } catch (_) {
      // Locked out by Android, not enrolled any more, cancelled...: the
      // caller falls back to the PIN.
      return false;
    }
  }
}
