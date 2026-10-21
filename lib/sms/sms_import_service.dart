import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/data_exception.dart';
import '../models/transaction_category.dart';
import '../models/transaction_model.dart';
import 'sms_categorizer.dart';
import 'sms_gateway.dart';
import 'sms_parser.dart';
import 'sms_settings.dart';
import 'sms_transaction.dart';

/// Saves a detected transaction unless it already exists; returns true if
/// it was added. In the app this is `TransactionStore.addDetected`.
typedef SaveDetected = Future<bool> Function(
    TransactionModel transaction, String dedupeKey);

/// Automatic transaction detection for the signed-in user.
///
/// Flow: Android hands over M-Pesa / Airtel SMS (and only those) ->
/// [SmsParser] reads the amount, code, etc. -> [SmsCategorizer] picks a
/// category -> the transaction is saved through the normal transaction
/// repository, into the same `users/{uid}/transactions` collection that
/// manual entries use.
///
/// When it runs:
/// * while the app is open, each new SMS as it arrives;
/// * when the app starts or comes back to the foreground, every SMS that
///   arrived since the last check (this covers the time the app was closed).
class SmsImportService extends ChangeNotifier {
  SmsImportService({
    required this._gateway,
    required this._settings,
    required this._save,
  });

  final SmsGateway _gateway;
  final SmsSettings _settings;
  final SaveDetected _save;

  final _detected = StreamController<TransactionModel>.broadcast();
  StreamSubscription<RawSms>? _incoming;

  /// Handles one message at a time, so a live SMS and an inbox scan can't
  /// race each other on the same transaction.
  Future<void> _queue = Future.value();

  bool _enabled = false;
  bool _hasPermission = false;
  bool _isScanning = false;
  DateTime? _lastScan;
  String? _lastError;
  bool _disposed = false;

  /// Only Android can read SMS. Elsewhere the feature is hidden/disabled.
  bool get isSupported => _gateway.isSupported;

  /// The user's ON/OFF choice in Settings.
  bool get isEnabled => _enabled;

  bool get hasPermission => _hasPermission;

  /// On, and Android lets us read SMS: detection is actually running.
  bool get isActive => isSupported && _enabled && _hasPermission;

  bool get isScanning => _isScanning;
  DateTime? get lastScan => _lastScan;

  /// Why the last scan stopped early (e.g. offline), or null.
  String? get lastError => _lastError;

  /// Every transaction that was newly added, for the in-app notification.
  Stream<TransactionModel> get detected => _detected.stream;

  /// Loads the saved setting and, if detection is on, catches up on missed
  /// messages and starts listening. Safe to call on any platform.
  Future<void> start() async {
    if (!isSupported) return;
    try {
      _enabled = await _settings.isEnabled();
      _lastScan = await _settings.lastScan();
      _hasPermission = await _gateway.hasPermission();
      _notify();
      await _resume();
    } catch (e) {
      debugPrint('SMS detection could not start: $e');
    }
  }

  /// Call when the app returns to the foreground: the user may have changed
  /// the permission in Settings, and new SMS may have arrived meanwhile.
  Future<void> onAppResumed() async {
    if (!isSupported) return;
    try {
      _hasPermission = await _gateway.hasPermission();
      _notify();
      await _resume();
    } catch (e) {
      debugPrint('SMS detection resume failed: $e');
    }
  }

  Future<SmsPermissionStatus> requestPermission() async {
    final status = await _gateway.requestPermission();
    _hasPermission = status == SmsPermissionStatus.granted;
    _notify();
    return status;
  }

  Future<void> openAppSettings() => _gateway.openAppSettings();

  /// Turns detection on. The caller must have the permission already.
  ///
  /// Only messages arriving from now on are imported; older ones can be
  /// imported on purpose with [scanRecent].
  Future<void> enable() async {
    _enabled = true;
    await _settings.setEnabled(true);
    if (_lastScan == null) {
      _lastScan = DateTime.now();
      await _settings.setLastScan(_lastScan!);
    }
    _notify();
    await _resume();
  }

  /// Turns detection off. Nothing is read or created until it's turned on
  /// again. Transactions already imported stay (they're normal transactions).
  Future<void> disable() async {
    _enabled = false;
    await _settings.setEnabled(false);
    await _stopListening();
    _notify();
  }

  /// Imports transaction SMS from the last [days] days. Duplicates are
  /// skipped, so running it again is harmless. Returns how many were added.
  Future<int> scanRecent({int days = 30}) async {
    if (!isActive) return 0;
    return _scanSince(DateTime.now().subtract(Duration(days: days)),
        advanceLastScan: false);
  }

  /// Parses, categorises and saves one SMS. Returns the saved transaction,
  /// or null if it wasn't a transaction or was already saved.
  ///
  /// Public so tests can feed it sample messages.
  Future<TransactionModel?> handle(RawSms sms) {
    final result = _queue.then((_) => _handleNow(sms));
    // Keep the queue going even if this one fails.
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<TransactionModel?> _handleNow(RawSms sms) async {
    if (!_enabled) return null; // turned off while this was queued

    final parsed =
        SmsParser.parse(sender: sms.sender, body: sms.body, date: sms.date);
    if (parsed == null) return null; // not a transaction: ignore it entirely

    final key = parsed.dedupeKey;
    // First check, on the device: already handled here (even if the user
    // deleted it afterwards, we don't bring it back).
    if ((await _settings.handledKeys()).contains(key)) return null;

    final transaction = toTransaction(parsed);
    // Second check, in Firestore: the repository only creates the document
    // if no document with this key exists (e.g. imported on another phone).
    final added = await _save(transaction, key);
    await _settings.addHandledKey(key);
    if (!added) return null;

    final saved = transaction.withId(key);
    if (!_detected.isClosed) _detected.add(saved);
    return saved;
  }

  /// Builds the transaction that gets saved, from a parsed SMS.
  static TransactionModel toTransaction(SmsTransaction t) {
    final type = t.type;
    final isCashMove = type == TransactionType.transfer;
    final details = [
      if (t.account != null) 'Account: ${SmsParser.maskDigits(t.account!)}',
      if (isCashMove && t.counterparty != null) 'Agent: ${t.counterparty}',
    ];
    final smsText = t.maskedText.length > 1000
        ? t.maskedText.substring(0, 1000)
        : t.maskedText;
    // The mobile-money wallet the SMS is about.
    final wallet = t.source == TransactionSource.airtel
        ? Account.airtelMoney
        : Account.mpesa;
    final isDeposit = t.kind == SmsTransactionKind.deposit;
    return TransactionModel(
      description: _description(t),
      amount: t.amount,
      type: type,
      categoryId: DefaultCategories.hasFixedCategory(type)
          ? DefaultCategories.fixedCategoryFor(type)
          : SmsCategorizer.categorize(t),
      date: t.date,
      note: details.isEmpty ? null : details.join('\n'),
      source: t.source,
      reference: t.reference,
      smsText: smsText,
      // A deposit moves cash into the wallet; a withdrawal the other way.
      account: isCashMove && isDeposit ? Account.cash : wallet,
      toAccount: isCashMove ? (isDeposit ? wallet : Account.cash) : null,
      // The provider's charge, stored as a number so it counts as spending.
      fee: (t.fee ?? 0) > 0 ? t.fee : null,
    );
  }

  static String _description(SmsTransaction t) {
    // Agent names say little about the transaction; the note keeps them.
    if (t.kind == SmsTransactionKind.withdrawal) return 'Cash withdrawal';
    if (t.kind == SmsTransactionKind.deposit) return 'Cash deposit';
    final name = t.counterparty;
    if (name != null && name.isNotEmpty) {
      return name.length > 100 ? name.substring(0, 100) : name;
    }
    return switch (t.kind) {
      SmsTransactionKind.airtime => 'Airtime',
      SmsTransactionKind.withdrawal => 'Cash withdrawal',
      SmsTransactionKind.deposit => 'Cash deposit',
      SmsTransactionKind.received => '${t.source.label} received',
      SmsTransactionKind.sent => '${t.source.label} transfer',
      SmsTransactionKind.payment => '${t.source.label} payment',
    };
  }

  /// Starts listening and catches up on missed messages, if detection is
  /// on; otherwise makes sure nothing is running.
  Future<void> _resume() async {
    if (!isActive) {
      await _stopListening();
      return;
    }
    _incoming ??= _gateway
        .incoming(senders: SmsParser.allSenders)
        .listen((sms) => handle(sms).catchError((Object e) {
              debugPrint('Could not save detected transaction: $e');
              return null;
            }));
    await _scanSince(_lastScan ?? DateTime.now(), advanceLastScan: true);
  }

  Future<int> _scanSince(DateTime since, {required bool advanceLastScan}) async {
    if (_isScanning) return 0;
    _isScanning = true;
    _lastError = null;
    _notify();

    // Taken before reading, so an SMS arriving during the scan is newer than
    // this and is picked up next time (or live) rather than skipped.
    final scanTime = DateTime.now();
    var added = 0;
    var completed = false;
    DateTime? lastOk;
    try {
      final messages = await _gateway.readInbox(
          senders: SmsParser.allSenders, since: since);
      for (final sms in messages) {
        if (await handle(sms) != null) added++;
        lastOk = sms.date;
      }
      completed = true;
    } on DataException catch (e) {
      // Usually offline. Stop here; the rest is retried next time.
      _lastError = e.message;
    } catch (e) {
      debugPrint('SMS scan failed: $e');
      _lastError = 'Couldn\'t check your messages. Please try again.';
    }

    if (advanceLastScan) {
      // Everything up to scanTime is done, or up to the last message that
      // was saved if the scan stopped early.
      final newLastScan = completed ? scanTime : lastOk;
      if (newLastScan != null &&
          (_lastScan == null || newLastScan.isAfter(_lastScan!))) {
        _lastScan = newLastScan;
        await _settings.setLastScan(newLastScan);
      }
    }
    _isScanning = false;
    _notify();
    return added;
  }

  Future<void> _stopListening() async {
    await _incoming?.cancel();
    _incoming = null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _incoming?.cancel();
    _detected.close();
    super.dispose();
  }
}
