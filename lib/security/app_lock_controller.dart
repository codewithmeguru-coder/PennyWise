import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';

import 'app_lock_store.dart';
import 'device_security.dart';
import 'pin_hasher.dart';

enum AppLockStatus {
  /// Reading the settings at start-up. Nothing is shown yet.
  loading,

  /// App Lock is off.
  off,

  /// App Lock is on and the PIN (or biometrics) is needed.
  locked,

  /// App Lock is on and the user has unlocked.
  unlocked,

  /// App Lock data exists but couldn't be read (e.g. restored onto another
  /// phone). Stays locked; the only way out is "Forgot PIN? Sign out".
  unreadable,
}

/// Result of checking a PIN.
class PinCheck {
  const PinCheck._(this.ok, {this.triesLeft, this.wait});

  static const correct = PinCheck._(true);

  /// Wrong PIN; [triesLeft] before a lockout, or [wait] if one started.
  const PinCheck.wrong({int? triesLeft, Duration? wait})
      : this._(false, triesLeft: triesLeft, wait: wait);

  /// Too many wrong PINs: nothing is checked until [wait] has passed.
  const PinCheck.lockedOut(Duration wait) : this._(false, wait: wait);

  final bool ok;
  final int? triesLeft;
  final Duration? wait;
}

/// Decides when PennyWise is locked, and checks PINs and biometrics.
///
/// App Lock is a device setting: it is separate from Firebase sign-in, and
/// locking or unlocking never signs anyone in or out.
class AppLockController extends ChangeNotifier {
  AppLockController({
    AppLockStore? store,
    this._hasher = const PinHasher(),
    BiometricAuth? biometrics,
    this._privacy = const DevicePrivacy(),
    DateTime Function()? now,
    Duration Function()? elapsed,
  })  : _store = store ?? SecureAppLockStore(),
        _biometrics = biometrics ?? LocalBiometricAuth(),
        _now = now ?? DateTime.now,
        _elapsed = elapsed ?? _stopwatch();

  static Duration Function() _stopwatch() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  final AppLockStore _store;
  final PinHasher _hasher;
  final BiometricAuth _biometrics;
  final DevicePrivacy _privacy;

  /// Wall clock: only for lockouts, which must survive a restart.
  final DateTime Function() _now;

  /// Monotonic time since start: for the background timeout, so changing the
  /// phone's clock can't skip it.
  final Duration Function() _elapsed;

  /// Wrong PINs allowed before the first lockout.
  static const maxTries = 5;
  static const firstLockout = Duration(seconds: 30);
  static const maxLockout = Duration(minutes: 15);
  static const timeouts = [
    Duration.zero,
    Duration(minutes: 1),
    Duration(minutes: 5),
  ];

  AppLockStatus _status = AppLockStatus.loading;
  AppLockConfig? _config;
  bool _biometricsAvailable = false;
  Duration? _backgroundedAt;
  int _lockCount = 0;
  bool _disposed = false;

  AppLockStatus get status => _status;
  bool get isEnabled => _config != null;
  Duration get timeout => _config?.timeout ?? const Duration(minutes: 1);

  /// The device can use biometrics (hardware + enrolment + Android 9+).
  bool get biometricsAvailable => _biometricsAvailable;

  /// The user turned biometrics on, and the device still supports them.
  bool get biometricsEnabled =>
      (_config?.biometrics ?? false) && _biometricsAvailable;

  /// Changes every time the app locks, so the lock screen can offer the
  /// fingerprint prompt once per lock.
  int get lockCount => _lockCount;

  /// True while the app's own screens must be hidden.
  bool get blocksApp =>
      _status == AppLockStatus.loading ||
      _status == AppLockStatus.locked ||
      _status == AppLockStatus.unreadable;

  /// Time left in a lockout, or null if PINs can be entered.
  Duration? get lockoutRemaining {
    final until = _config?.lockedUntil;
    if (until == null) return null;
    final left = until.difference(_now());
    if (left <= Duration.zero) return null;
    // If the clock was moved back, never wait longer than the maximum.
    return left > maxLockout ? maxLockout : left;
  }

  /// Reads the saved settings. App Lock always starts locked when it's on,
  /// so restarting the app can't skip it.
  Future<void> init() async {
    try {
      _config = await _store.read();
      _status = _config == null ? AppLockStatus.off : AppLockStatus.locked;
      if (_config != null) _lockCount++;
    } catch (_) {
      // Don't log the error: it could contain stored data.
      debugPrint('App Lock settings could not be read');
      _status = AppLockStatus.unreadable;
    }
    _biometricsAvailable = await _biometrics.isAvailable();
    await _privacy.hideRecentsPreview(_status != AppLockStatus.off);
    _notify();
  }

  /// Re-checks biometrics, e.g. after the user enrolled a fingerprint.
  Future<void> refreshBiometrics() async {
    _biometricsAvailable = await _biometrics.isAvailable();
    _notify();
  }

  /// Call on every app lifecycle change.
  ///
  /// Only `hidden` / `paused` (another app, home screen, screen off) start
  /// the timeout. `inactive` doesn't: system dialogs on top of PennyWise
  /// (permission requests, the Google account picker, the fingerprint
  /// prompt) cause it, and locking then would interrupt the user.
  void handleLifecycle(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        if (_status != AppLockStatus.unlocked) return;
        _backgroundedAt ??= _elapsed();
        // "Immediately": lock now, so the app is already locked when it's
        // next seen (including in the recent-apps screen).
        if (timeout == Duration.zero) _lock();
      case AppLifecycleState.resumed:
        final since = _backgroundedAt;
        _backgroundedAt = null;
        if (_status == AppLockStatus.unlocked &&
            since != null &&
            _elapsed() - since >= timeout) {
          _lock();
        }
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  void _lock() {
    _status = AppLockStatus.locked;
    _lockCount++;
    _notify();
  }

  /// Checks [pin] on the lock screen; unlocks if it's right.
  Future<PinCheck> unlockWithPin(String pin) async {
    final check = await checkPin(pin);
    if (check.ok && _status == AppLockStatus.locked) {
      _status = AppLockStatus.unlocked;
      _notify();
    }
    return check;
  }

  /// Checks [pin] without changing the lock state (settings use this before
  /// changing the PIN or turning App Lock off). Wrong PINs count towards
  /// the lockout here too.
  Future<PinCheck> checkPin(String pin) async {
    final config = _config;
    if (config == null) return const PinCheck.wrong();
    if (lockoutRemaining case final wait?) return PinCheck.lockedOut(wait);

    if (await _hasher.verify(pin, config.pin)) {
      await _save(config.copyWith(failures: 0, clearLockedUntil: true));
      return PinCheck.correct;
    }

    final failures = config.failures + 1;
    if (failures < maxTries) {
      await _save(config.copyWith(failures: failures));
      return PinCheck.wrong(triesLeft: maxTries - failures);
    }
    final wait = lockoutFor(failures);
    await _save(config.copyWith(
      failures: failures,
      lockedUntil: _now().add(wait),
    ));
    return PinCheck.wrong(wait: wait);
  }

  /// 5 wrong PINs: 30 s. Each further wrong PIN doubles it, up to 15 min.
  static Duration lockoutFor(int failures) {
    if (failures < maxTries) return Duration.zero;
    final doublings = min(failures - maxTries, 10);
    final seconds = firstLockout.inSeconds * (1 << doublings);
    return seconds >= maxLockout.inSeconds
        ? maxLockout
        : Duration(seconds: seconds);
  }

  /// Shows the fingerprint / face prompt; unlocks if recognised. The PIN
  /// stays available whatever happens.
  Future<bool> unlockWithBiometrics() async {
    if (!biometricsEnabled || _status != AppLockStatus.locked) return false;
    final ok = await _biometrics.authenticate('Unlock PennyWise');
    if (!ok || _status != AppLockStatus.locked) return false;
    final config = _config;
    if (config != null && (config.failures > 0 || config.lockedUntil != null)) {
      await _save(config.copyWith(failures: 0, clearLockedUntil: true));
    }
    _status = AppLockStatus.unlocked;
    _notify();
    return true;
  }

  /// Turns App Lock on with a new [pin] (already confirmed by the user).
  Future<void> enable(String pin) async {
    await _save(AppLockConfig(pin: await _hasher.hash(pin)));
    _status = AppLockStatus.unlocked;
    await _privacy.hideRecentsPreview(true);
    _notify();
  }

  /// Replaces the PIN. The caller must have checked the current one.
  Future<void> changePin(String newPin) async {
    final config = _config;
    if (config == null) return;
    await _save(config.copyWith(
      pin: await _hasher.hash(newPin),
      failures: 0,
      clearLockedUntil: true,
    ));
  }

  Future<void> setTimeout(Duration timeout) async {
    final config = _config;
    if (config == null) return;
    await _save(config.copyWith(timeout: timeout));
  }

  /// Turns biometric unlock on (after one successful scan, to prove it
  /// works) or off.
  Future<bool> setBiometrics(bool enabled) async {
    final config = _config;
    if (config == null) return false;
    if (enabled) {
      if (!_biometricsAvailable) return false;
      if (!await _biometrics.authenticate('Confirm it\'s you to turn on '
          'fingerprint unlock')) {
        return false;
      }
    }
    await _save(config.copyWith(biometrics: enabled));
    return true;
  }

  /// Turns App Lock off. The caller must have checked the PIN.
  Future<void> disable() => _clearLocalLock();

  /// "Forgot PIN? Sign out": clears App Lock on this device only. The
  /// caller signs out of Firebase first; nothing in the cloud is touched.
  Future<void> resetAfterSignOut() => _clearLocalLock();

  Future<void> _clearLocalLock() async {
    await _store.clear();
    _config = null;
    _backgroundedAt = null;
    _status = AppLockStatus.off;
    await _privacy.hideRecentsPreview(false);
    _notify();
  }

  Future<void> _save(AppLockConfig config) async {
    await _store.write(config);
    _config = config;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
