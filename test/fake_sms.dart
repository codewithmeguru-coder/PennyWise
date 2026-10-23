import 'dart:async';

import 'package:pennywise/sms/sms_gateway.dart';
import 'package:pennywise/sms/sms_parser.dart';
import 'package:pennywise/sms/sms_settings.dart';

/// Stand-in for the phone's SMS system, so tests need no Android device and
/// no real transactions.
class FakeSmsGateway implements SmsGateway {
  FakeSmsGateway({
    this.isSupported = true,
    this.permissionGranted = false,
    this.answer = SmsPermissionStatus.granted,
  });

  @override
  final bool isSupported;

  bool permissionGranted;

  /// What the user "answers" in Android's permission dialog.
  SmsPermissionStatus answer;

  int permissionRequests = 0;
  int openedSettings = 0;

  /// The phone's inbox (any senders; filtered like the Android side does).
  final List<RawSms> inbox = [];

  final _incoming = StreamController<RawSms>.broadcast();

  /// Simulates an SMS arriving while the app is open.
  void receive(RawSms sms) {
    inbox.add(sms);
    if (SmsParser.sourceFor(sms.sender) != null) _incoming.add(sms);
  }

  @override
  Future<bool> hasPermission() async => permissionGranted;

  @override
  Future<SmsPermissionStatus> requestPermission() async {
    permissionRequests++;
    permissionGranted = answer == SmsPermissionStatus.granted;
    return answer;
  }

  @override
  Future<void> openAppSettings() async => openedSettings++;

  @override
  Future<List<RawSms>> readInbox({
    required List<String> senders,
    required DateTime since,
  }) async {
    if (!permissionGranted) throw StateError('no permission');
    return inbox
        .where((m) =>
            senders.contains(SmsParser.normalizeSender(m.sender)) &&
            m.date.isAfter(since))
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));
  }

  @override
  Stream<RawSms> incoming({required List<String> senders}) => _incoming.stream;
}

/// In-memory [SmsSettings].
class FakeSmsSettings implements SmsSettings {
  FakeSmsSettings({this.enabled = false, this.last});

  bool enabled;
  DateTime? last;
  final Set<String> handled = {};

  @override
  Future<bool> isEnabled() async => enabled;

  @override
  Future<void> setEnabled(bool value) async => enabled = value;

  @override
  Future<DateTime?> lastScan() async => last;

  @override
  Future<void> setLastScan(DateTime time) async => last = time;

  @override
  Future<Set<String>> handledKeys() async => {...handled};

  @override
  Future<void> addHandledKey(String key) async => handled.add(key);

  final skipped = <SkipReason, Set<String>>{};

  @override
  Future<Map<SkipReason, int>> skippedCounts() async =>
      {for (final r in SkipReason.values) r: skipped[r]?.length ?? 0};

  @override
  Future<void> recordSkipped(SkipReason reason, String key) async =>
      (skipped[reason] ??= {}).add(key);
}
