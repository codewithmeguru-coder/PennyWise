import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'pin_hasher.dart';

/// Everything App Lock keeps on this device. Stored only in secure storage
/// (Android Keystore), never in SharedPreferences or Firestore.
class AppLockConfig {
  const AppLockConfig({
    required this.pin,
    this.timeout = const Duration(minutes: 1),
    this.biometrics = false,
    this.failures = 0,
    this.lockedUntil,
  });

  final PinHash pin;

  /// How long the app may stay in the background before it locks.
  final Duration timeout;

  /// The user chose to unlock with fingerprint / face as well as the PIN.
  final bool biometrics;

  /// Wrong PINs in a row since the last successful unlock.
  final int failures;

  /// No PIN is accepted before this time (after too many wrong PINs).
  final DateTime? lockedUntil;

  AppLockConfig copyWith({
    PinHash? pin,
    Duration? timeout,
    bool? biometrics,
    int? failures,
    DateTime? lockedUntil,
    bool clearLockedUntil = false,
  }) =>
      AppLockConfig(
        pin: pin ?? this.pin,
        timeout: timeout ?? this.timeout,
        biometrics: biometrics ?? this.biometrics,
        failures: failures ?? this.failures,
        lockedUntil: clearLockedUntil ? null : lockedUntil ?? this.lockedUntil,
      );

  Map<String, Object?> toJson() => {
        'v': 1,
        'pin': pin.toJson(),
        'timeoutSeconds': timeout.inSeconds,
        'biometrics': biometrics,
        'failures': failures,
        'lockedUntilMs': lockedUntil?.millisecondsSinceEpoch,
      };

  static AppLockConfig fromJson(Map<String, dynamic> json) => AppLockConfig(
        pin: PinHash.fromJson(json['pin'] as Map<String, dynamic>),
        timeout: Duration(seconds: json['timeoutSeconds'] as int),
        biometrics: json['biometrics'] as bool,
        failures: json['failures'] as int,
        lockedUntil: switch (json['lockedUntilMs']) {
          final int ms => DateTime.fromMillisecondsSinceEpoch(ms),
          _ => null,
        },
      );
}

/// Reads and writes the [AppLockConfig]. Null means App Lock is off.
abstract class AppLockStore {
  /// Throws if the stored data exists but can't be read.
  Future<AppLockConfig?> read();
  Future<void> write(AppLockConfig config);
  Future<void> clear();
}

/// [AppLockStore] in `flutter_secure_storage`, which on Android encrypts
/// with a key held in the Android Keystore.
class SecureAppLockStore implements AppLockStore {
  SecureAppLockStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(aOptions: AndroidOptions());

  final FlutterSecureStorage _storage;

  static const _key = 'pennywise.app_lock.v1';

  @override
  Future<AppLockConfig?> read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return null;
    return AppLockConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  @override
  Future<void> write(AppLockConfig config) =>
      _storage.write(key: _key, value: jsonEncode(config.toJson()));

  @override
  Future<void> clear() => _storage.delete(key: _key);
}
