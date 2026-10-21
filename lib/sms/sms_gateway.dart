import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One SMS as delivered by Android: only these three fields, and only for
/// the allowed mobile-money senders (Android filters out everything else).
class RawSms {
  const RawSms({required this.sender, required this.body, required this.date});

  final String sender;
  final String body;
  final DateTime date;
}

/// Result of asking Android for SMS permission.
enum SmsPermissionStatus {
  granted,

  /// Denied, but the app may ask again.
  denied,

  /// Denied with "Don't ask again" (or denied twice). Only the system
  /// Settings app can grant it now.
  permanentlyDenied,
}

/// Everything PennyWise needs from the phone's SMS system.
///
/// An interface so the rest of the app (and tests) don't depend on Android.
abstract class SmsGateway {
  /// False on web, Windows, iOS, etc. Nothing else should be called then.
  bool get isSupported;

  Future<bool> hasPermission();

  /// Shows Android's permission dialog. Only call this after explaining to
  /// the user why the permission is needed.
  Future<SmsPermissionStatus> requestPermission();

  /// Opens PennyWise's page in the system Settings app.
  Future<void> openAppSettings();

  /// Messages from [senders] received after [since], oldest first.
  Future<List<RawSms>> readInbox({
    required List<String> senders,
    required DateTime since,
  });

  /// Messages from [senders] as they arrive, while the app is running.
  Stream<RawSms> incoming({required List<String> senders});
}

/// [SmsGateway] backed by `SmsBridge.kt` through platform channels.
class AndroidSmsGateway implements SmsGateway {
  static const _methods = MethodChannel('pennywise/sms');
  static const _events = EventChannel('pennywise/sms_incoming');

  @override
  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<bool> hasPermission() async {
    if (!isSupported) return false;
    return await _methods.invokeMethod<bool>('hasPermission') ?? false;
  }

  @override
  Future<SmsPermissionStatus> requestPermission() async {
    if (!isSupported) return SmsPermissionStatus.denied;
    final result = await _methods.invokeMethod<String>('requestPermission');
    return switch (result) {
      'granted' => SmsPermissionStatus.granted,
      'permanentlyDenied' => SmsPermissionStatus.permanentlyDenied,
      _ => SmsPermissionStatus.denied,
    };
  }

  @override
  Future<void> openAppSettings() async {
    if (!isSupported) return;
    await _methods.invokeMethod<void>('openAppSettings');
  }

  @override
  Future<List<RawSms>> readInbox({
    required List<String> senders,
    required DateTime since,
  }) async {
    if (!isSupported) return const [];
    final rows = await _methods.invokeListMethod<Map<Object?, Object?>>(
      'readInbox',
      {'senders': senders, 'since': since.millisecondsSinceEpoch},
    );
    return [for (final row in rows ?? const []) _toSms(row)];
  }

  @override
  Stream<RawSms> incoming({required List<String> senders}) {
    if (!isSupported) return const Stream.empty();
    return _events
        .receiveBroadcastStream({'senders': senders})
        .map((event) => _toSms(event as Map<Object?, Object?>));
  }

  static RawSms _toSms(Map<Object?, Object?> map) => RawSms(
        sender: map['sender'] as String? ?? '',
        body: map['body'] as String? ?? '',
        date: DateTime.fromMillisecondsSinceEpoch(map['date'] as int),
      );
}
