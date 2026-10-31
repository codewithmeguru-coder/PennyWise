import 'dart:async';

import 'package:flutter/foundation.dart';

import '../accounts/account_repository.dart';
import '../accounts/money_account.dart';
import '../categorization/category_rule.dart';
import '../data/data_exception.dart';
import '../models/transaction_category.dart';
import '../models/transaction_model.dart';
import '../services/exchange_rates.dart';
import 'estimated_amount.dart';
import 'sms_categorizer.dart';
import 'sms_gateway.dart';
import 'sms_parser.dart';
import 'sms_settings.dart';
export 'sms_settings.dart' show SkipReason;
import 'sms_transaction.dart';

/// Saves a detected transaction unless it already exists; returns true if
/// it was added. In the app this is `TransactionStore.addDetected`.
typedef SaveDetected = Future<bool> Function(
  TransactionModel transaction,
  String dedupeKey,
);

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
    this._rules = _noRules,
    this._accounts = _noAccounts,
    this._isSaved = _neverSaved,
    this._rates,
  });

  /// That day's market rate for card payments in another currency; null
  /// holds them instead.
  final ExchangeRates? _rates;

  static bool _neverSaved(String id) => false;

  /// Whether a transaction with this id is already saved (e.g. the M-Pesa
  /// record of a top-up into Equity).
  final bool Function(String id) _isSaved;

  static AccountResolver? _noAccounts() => null;

  /// The user's accounts, to put each SMS on the right SIM's account.
  final AccountResolver? Function() _accounts;

  static Map<String, CategoryRule> _noRules() => const {};

  final SmsGateway _gateway;

  /// The user's learned category rules, read when each SMS is handled.
  final Map<String, CategoryRule> Function() _rules;
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
  Map<SkipReason, Set<String>> _skippedKeys = const {};

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

  /// Transaction messages not imported, by reason (see [SkipReason]).
  Map<SkipReason, int> get skipped => {
    for (final e in _skippedKeys.entries) e.key: e.value.length,
  };

  /// The codes behind [skipped] (not yet handled).
  Map<SkipReason, Set<String>> get skippedKeys => _skippedKeys;

  /// Detection is on but hasn't checked for messages in over 3 days (e.g.
  /// the app wasn't opened, or something keeps failing). Detection only
  /// runs while PennyWise is open.
  bool get isStale {
    final last = _lastScan;
    return isEnabled &&
        isSupported &&
        last != null &&
        DateTime.now().difference(last) > const Duration(days: 3);
  }

  /// Every transaction that was newly added, for the in-app notification.
  Stream<TransactionModel> get detected => _detected.stream;

  /// Loads the saved setting and, if detection is on, catches up on missed
  /// messages and starts listening. Safe to call on any platform.
  Future<void> start() async {
    if (!isSupported) return;
    try {
      _enabled = await _settings.isEnabled();
      _lastScan = await _settings.lastScan();
      _skippedKeys = await _settings.skippedKeys();
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
    return _scanSince(
      DateTime.now().subtract(Duration(days: days)),
      advanceLastScan: false,
    );
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

    final parsed = SmsParser.parse(
      sender: sms.sender,
      body: sms.body,
      date: sms.date,
    );
    if (parsed == null) {
      // A completed transaction we can't read is counted (code only), so
      // Settings can say so instead of losing it silently. Promotions and
      // other non-transaction messages are ignored entirely.
      if (SmsParser.looksLikeTransaction(sender: sms.sender, body: sms.body)) {
        final code = sms.body.trim().split(RegExp(r'\s+')).first;
        await _recordSkipped(SkipReason.unreadable, code);
      }
      return null;
    }
    final key = parsed.dedupeKey;
    // First check, on the device: already handled here (even if the user
    // deleted it afterwards, we don't bring it back). Fuliza loans and
    // repayments brought in by Settings › Fuliza history are handled too.
    if ((await _settings.handledKeys()).contains(key)) return null;

    var transaction = toTransaction(
      parsed,
      rules: _rules(),
      simSlot: sms.simSlot,
      accounts: _accounts(),
    );
    if (parsed.source == TransactionSource.equity) {
      // A card payment in another currency: the SMS has no KES amount, so
      // it is saved at that day's market rate and marked as estimated for
      // the user to keep or correct. Without a rate (offline) it waits and
      // is tried again next time.
      if (parsed.currency != 'KES') {
        final rate = await _rates?.toKes(parsed.currency, parsed.date);
        if (rate == null) {
          await _recordSkipped(SkipReason.foreignCurrency, key);
          return null;
        }
        transaction = EstimatedAmount.withAmount(
          transaction,
          (parsed.amount * rate * 100).roundToDouble() / 100,
          EstimatedAmount.note(
            parsed.currency,
            parsed.amount,
            rate,
            parsed.date,
          ),
        );
      }
      // Money the user moved in from their own M-Pesa / Airtel: that side
      // is already saved under the same code, so a second record would
      // count it twice. Settings › Fix moves between your accounts turns it into a
      // move between the two accounts, after a preview.
      final via = parsed.viaMobileMoney;
      if (via != null &&
          (_isSaved('mpesa_$via') || _isSaved('airtel_$via'))) {
        await _recordSkipped(SkipReason.bankTopUp, key);
        return null;
      }
      // No Equity account yet: held, not recorded on no account.
      if (transaction.accountId == null) {
        await _recordSkipped(SkipReason.bankNoAccount, key);
        return null;
      }
    }
    final autoFuliza = parsed.kind.isFuliza && await autoFulizaImport();
    if (parsed.kind.isFuliza &&
        (!autoFuliza ||
            transaction.accountId == null ||
            transaction.toAccountId == null)) {
      // Held, not saved, unless the user turned on automatic Fuliza import
      // (off by default, so installing or opening the app never starts
      // it), and only with both its SIM's M-Pesa and Fuliza accounts known
      // (never guessed). Not marked handled, so Settings › Fuliza history
      // or a later import can still bring it in.
      await _recordSkipped(
        autoFuliza ? SkipReason.fulizaNoAccount : SkipReason.fulizaWaiting,
        key,
      );
      return null;
    }
    // Second check, in Firestore: the repository only creates the document
    // if no document with this key exists (e.g. imported on another phone).
    final added = await _save(transaction, key);
    await _settings.addHandledKey(key);
    if (!added) return null;

    final saved = transaction.withId(key);
    if (!_detected.isClosed) _detected.add(saved);
    return saved;
  }

  Future<void> _recordSkipped(SkipReason reason, String key) async {
    await _settings.recordSkipped(reason, key);
    _skippedKeys = await _settings.skippedKeys();
    _notify();
  }

  /// Builds the transaction that gets saved, from a parsed SMS.
  ///
  /// With [accounts], the transaction is put on the account of the SIM that
  /// received the SMS ([simSlot]); savings go to that SIM's savings account
  /// and cash moves to the Cash account. If the SIM is unknown or has no
  /// account, no account id is set (it shows as "SIM not recorded") rather
  /// than guessing: SIM 1 and SIM 2 are never mixed.
  static TransactionModel toTransaction(
    SmsTransaction t, {
    Map<String, CategoryRule> rules = const {},
    int? simSlot,
    AccountResolver? accounts,
  }) {
    final type = t.type;
    if (t.kind.isFuliza) {
      return _fuliza(t, simSlot: simSlot, accounts: accounts);
    }
    if (t.source == TransactionSource.equity) {
      return _bank(t, rules: rules, accounts: accounts);
    }
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
    final provider = t.source == TransactionSource.airtel
        ? AccountProvider.airtel
        : AccountProvider.safaricom;
    final walletId = accounts
        ?.forSim(simSlot, AccountKind.mobileMoney, provider: provider)
        ?.id;
    // Cash may be hidden from Home, but an agent withdrawal still moves
    // money between it and the SIM; without it the SIM side would be lost.
    final cashId =
        (accounts?.firstOf(AccountKind.cash) ??
                accounts?.firstOf(AccountKind.cash, includeHidden: true))
            ?.id;
    final savingsId =
        type == TransactionType.savingsContribution ||
            type == TransactionType.savingsWithdrawal
        ? accounts?.forSim(simSlot, AccountKind.savings, provider: provider)?.id
        : null;
    // Ids are only set when the wallet is known, so a half-known move
    // (e.g. Cash but no SIM) isn't recorded on one side only.
    final (String? accountId, String? toAccountId) = walletId == null
        ? (null, null)
        : isCashMove
        ? (isDeposit ? (cashId, walletId) : (walletId, cashId))
        : (walletId, savingsId);
    return TransactionModel(
      description: _description(t),
      amount: t.amount,
      type: type,
      categoryId: DefaultCategories.hasFixedCategory(type)
          ? DefaultCategories.fixedCategoryFor(type)
          : SmsCategorizer.categorize(t, rules: rules),
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
      // A cash move needs both sides; otherwise leave both unset.
      accountId: isCashMove && (accountId == null || toAccountId == null)
          ? null
          : accountId,
      toAccountId: isCashMove && (accountId == null || toAccountId == null)
          ? null
          : toAccountId,
      simSlot: simSlot,
    );
  }

  /// A Fuliza message, between that SIM's Fuliza loan and its M-Pesa:
  /// - draw: a transfer Fuliza (SIM n) -> M-Pesa (SIM n). The access fee is
  ///   its [TransactionModel.fee], so the loan grows by amount + fee and the
  ///   fee counts as spending once. It has no generic `account` (there is no
  ///   generic "Fuliza"), only `toAccount` M-Pesa, so it is never a cash
  ///   move and never income.
  /// - repayment: a debt repayment M-Pesa (SIM n) -> Fuliza (SIM n), which
  ///   lowers what is owed.
  /// Without both account ids (SIM unknown, or no accounts set up) the ids
  /// are left out; such a transaction is for review only, never saved
  /// (see `FulizaImporter`).
  static TransactionModel _fuliza(
    SmsTransaction t, {
    int? simSlot,
    AccountResolver? accounts,
  }) {
    final walletId = accounts?.forSim(simSlot, AccountKind.mobileMoney)?.id;
    final loanId = accounts?.forSim(simSlot, AccountKind.loan)?.id;
    final known = walletId != null && loanId != null;
    final isDraw = t.kind == SmsTransactionKind.fulizaDraw;
    final type = t.type; // transfer or debtRepayment
    return TransactionModel(
      description: _description(t),
      amount: t.amount,
      type: type,
      categoryId: DefaultCategories.fixedCategoryFor(type),
      date: t.date,
      source: t.source,
      reference: t.reference,
      smsText: t.maskedText.length > 1000
          ? t.maskedText.substring(0, 1000)
          : t.maskedText,
      account: isDraw ? null : Account.mpesa,
      toAccount: isDraw ? Account.mpesa : null,
      fee: isDraw && (t.fee ?? 0) > 0 ? t.fee : null,
      accountId: !known ? null : (isDraw ? loanId : walletId),
      toAccountId: !known ? null : (isDraw ? walletId : loanId),
      simSlot: simSlot,
    );
  }

  /// An Equity Bank SMS about the user's own account: on their Equity
  /// account (none: left unset, and the import holds it). A withdrawal
  /// moves money from the bank to Cash; a bank charge is a fee.
  static TransactionModel _bank(
    SmsTransaction t, {
    Map<String, CategoryRule> rules = const {},
    AccountResolver? accounts,
  }) {
    final type = t.type;
    final bankId = accounts?.bank(AccountProvider.equity)?.id;
    final isCashMove = t.kind == SmsTransactionKind.withdrawal;
    final cashId =
        (accounts?.firstOf(AccountKind.cash) ??
                accounts?.firstOf(AccountKind.cash, includeHidden: true))
            ?.id;
    final smsText = t.maskedText.length > 1000
        ? t.maskedText.substring(0, 1000)
        : t.maskedText;
    // A move needs both sides; otherwise neither is set.
    final (String? accountId, String? toAccountId) = bankId == null
        ? (null, null)
        : isCashMove
        ? (cashId == null ? (null, null) : (bankId, cashId))
        : (bankId, null);
    return TransactionModel(
      description: _description(t),
      amount: t.amount,
      type: type,
      categoryId: t.kind == SmsTransactionKind.charge
          ? 'fees'
          : DefaultCategories.hasFixedCategory(type)
          ? DefaultCategories.fixedCategoryFor(type)
          : SmsCategorizer.categorize(t, rules: rules),
      date: t.date,
      source: t.source,
      reference: t.reference,
      smsText: smsText,
      account: Account.bank,
      toAccount: isCashMove ? Account.cash : null,
      fee: (t.fee ?? 0) > 0 ? t.fee : null,
      accountId: accountId,
      toAccountId: toAccountId,
    );
  }

  /// A short, clear description built only from what the SMS says: who or
  /// what it was for, and how, never a guess. The SMS itself is kept as is.
  static String _description(SmsTransaction t) {
    // Agent names say little about the transaction; the note keeps them.
    if (t.kind == SmsTransactionKind.withdrawal) return 'Cash withdrawal';
    if (t.kind == SmsTransactionKind.deposit) return 'Cash deposit';
    // Airtime for another number names it (masked), as the SMS does.
    if (t.kind == SmsTransactionKind.airtime) {
      return t.phone == null
          ? 'Airtime'
          : 'Airtime for ${SmsParser.maskDigits(t.phone!)}';
    }
    final name = t.counterparty;
    if (name != null && name.isNotEmpty) {
      // Only what the message says, with the direction it gives: money
      // into or out of savings, sent to or received from someone. A
      // payment to a till keeps the business name alone; a Paybill also
      // names the account paid (masked), so bills to one business tell
      // apart; a bank card payment says it was by card.
      final via = t.viaMobileMoney == null
          ? ''
          : ' via ${t.source == TransactionSource.equity ? 'M-Pesa' : t.source.label}';
      final described = t.isSavingsProduct
          ? '$name ${t.kind == SmsTransactionKind.received ? 'withdrawal' : 'deposit'}'
          : switch (t.kind) {
              SmsTransactionKind.sent => 'Sent to $name',
              SmsTransactionKind.received => 'From $name$via',
              SmsTransactionKind.payment
                  when t.source == TransactionSource.equity =>
                'Card: $name',
              SmsTransactionKind.payment when t.account != null =>
                '$name · account ${SmsParser.maskDigits(t.account!)}',
              _ => name,
            };
      return described.length > 100 ? described.substring(0, 100) : described;
    }
    return switch (t.kind) {
      SmsTransactionKind.airtime => 'Airtime',
      SmsTransactionKind.withdrawal => 'Cash withdrawal',
      SmsTransactionKind.deposit => 'Cash deposit',
      SmsTransactionKind.received => '${t.source.label} received',
      SmsTransactionKind.sent => '${t.source.label} transfer',
      SmsTransactionKind.payment => '${t.source.label} payment',
      SmsTransactionKind.fulizaDraw => 'Fuliza loan',
      SmsTransactionKind.fulizaRepayment => 'Fuliza repayment',
      SmsTransactionKind.charge => '${t.source.label} charge',
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
        .listen(
          (sms) => handle(sms).catchError((Object e) {
            debugPrint('Could not save detected transaction: $e');
            return null;
          }),
        );
    await _scanSince(_lastScan ?? DateTime.now(), advanceLastScan: true);
    await retryHeld();
  }

  /// Held for a reason that can clear by itself: no exchange rate yet
  /// (offline), or the account wasn't set up yet. Not Fuliza read with
  /// automatic import off: that waits for Fuliza history.
  static const _retryable = {
    SkipReason.foreignCurrency,
    SkipReason.bankNoAccount,
    SkipReason.fulizaNoAccount,
  };

  /// Held messages that may be added once their reason clears.
  int get retryableCount => {
    for (final r in _retryable) ...?_skippedKeys[r],
  }.length;

  /// Reads held messages again (they are older than the last check, so the
  /// usual scan never sees them) and adds any that can be added now.
  /// Returns how many were added. Safe to repeat: each is saved at most
  /// once, by its code.
  Future<int> retryHeld() async {
    final held = {
      for (final r in _retryable) ...?_skippedKeys[r],
    };
    if (held.isEmpty || _isScanning || !isActive) return 0;
    var added = 0;
    try {
      final messages = await _gateway.readInbox(
        senders: SmsParser.allSenders,
        since: DateTime.now().subtract(const Duration(days: 31)),
      );
      for (final sms in messages) {
        final p = SmsParser.parse(
          sender: sms.sender,
          body: sms.body,
          date: sms.date,
        );
        if (p != null &&
            held.contains(p.dedupeKey) &&
            await handle(sms) != null) {
          added++;
        }
      }
    } catch (e) {
      debugPrint('Retrying held messages failed: $e');
    }
    return added;
  }

  Future<int> _scanSince(
    DateTime since, {
    required bool advanceLastScan,
  }) async {
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
        senders: SmsParser.allSenders,
        since: since,
      );
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

  /// Automatic Fuliza import (see [SmsSettings.autoFulizaImport]): off
  /// until the user turns it on. Off too if the setting can't be read.
  Future<bool> autoFulizaImport() async {
    try {
      return await _settings.autoFulizaImport();
    } catch (e) {
      debugPrint('Fuliza import setting unreadable, treated as off: $e');
      return false;
    }
  }

  Future<void> setAutoFulizaImport(bool on) async {
    await _settings.setAutoFulizaImport(on);
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _incoming?.cancel();
    _detected.close();
    super.dispose();
  }
}
