import '../accounts/account_repository.dart';
import '../data/data_exception.dart';
import '../models/transaction_model.dart';
import 'sms_gateway.dart';
import 'sms_import_service.dart';
import 'sms_parser.dart';
import 'sms_settings.dart';
import 'sms_transaction.dart';

/// Why a Fuliza message is or isn't imported.
enum FulizaStatus {
  /// Both accounts known and not saved yet: imported on request.
  eligible,

  /// A transaction with this key already exists; never overwritten.
  alreadyImported,

  /// The same message appears again in the inbox; counted once.
  repeated,

  /// The SIM, or that SIM's M-Pesa / Fuliza account, is unknown. Never
  /// guessed, so never imported.
  needsReview,
}

/// One Fuliza message and what an import would do with it.
class FulizaItem {
  const FulizaItem(this.sms, this.transaction, this.status);

  final SmsTransaction sms;

  /// What would be saved (see `SmsImportService.toTransaction`).
  final TransactionModel transaction;
  final FulizaStatus status;

  String get key => sms.dedupeKey;
  bool get isDraw => sms.kind == SmsTransactionKind.fulizaDraw;
}

/// Totals for one SIM among the messages that would be imported.
class FulizaSimTotals {
  int draws = 0, repayments = 0;
  double borrowed = 0, fees = 0, repaid = 0;

  /// How much this import adds to what is owed on that SIM's Fuliza.
  double get debtChange => borrowed + fees - repaid;
}

/// The result of reading the inbox, before anything is written.
class FulizaPreview {
  const FulizaPreview(this.items, {this.paymentsSaved = const {}});

  final List<FulizaItem> items;

  /// Keys of loans whose funded payment (same code, `mpesa_<code>`) is
  /// already saved: importing the loan adds the borrowing and its fee, and
  /// never a second payment.
  final Set<String> paymentsSaved;

  /// The records an import would create, under the ids they'd be saved as.
  List<TransactionModel> get toCreate =>
      [for (final i in eligible) i.transaction.withId(i.key)];

  /// Eligible loans whose payment is already saved.
  int get withPaymentSaved =>
      eligible.where((i) => i.isDraw && paymentsSaved.contains(i.key)).length;

  List<FulizaItem> get eligible =>
      [for (final i in items) if (i.status == FulizaStatus.eligible) i];

  int count(FulizaStatus s) => items.where((i) => i.status == s).length;

  /// Per SIM slot (0 = SIM 1), eligible messages only.
  Map<int, FulizaSimTotals> get bySim {
    final out = <int, FulizaSimTotals>{};
    for (final i in eligible) {
      final totals = out[i.transaction.simSlot!] ??= FulizaSimTotals();
      if (i.isDraw) {
        totals
          ..draws += 1
          ..borrowed += i.sms.amount
          ..fees += i.sms.fee ?? 0;
      } else {
        totals
          ..repayments += 1
          ..repaid += i.sms.amount;
      }
    }
    return out;
  }
}

/// What an import or Undo did.
class FulizaRunResult {
  const FulizaRunResult({this.done = 0, this.skipped = 0, this.error});

  /// Records created (import) or deleted (Undo).
  final int done;

  /// Import: already existed, so left as they were.
  final int skipped;

  /// Why it stopped early, if it did. Everything done before that is kept
  /// in the list of imported ids.
  final String? error;
}

/// Imports Fuliza loans and repayments from the phone's messages, on the
/// user's request, into the signed-in profile only.
///
/// - [preview] only reads: the inbox and the ids already in the store.
/// - [importEligible] creates only missing records (the repository's
///   create-if-absent, as for any SMS) and never touches existing ones. Each
///   created id is saved to this profile's list straight away, so a failure
///   part-way keeps an exact list; a message is marked handled only after
///   its record is saved.
/// - [undo] deletes exactly the ids on that list, nothing else. Handled
///   keys stay, so the deleted ones are not brought back automatically.
/// Calls while one is running are ignored, so repeated taps can't import
/// twice.
class FulizaImporter {
  FulizaImporter({
    required this._gateway,
    required this._settings,
    required this._accounts,
    required this._existingIds,
    required this._save,
    required this._delete,
  });

  /// Fuliza history is imported from this date on (the approved window).
  static final since = DateTime(2026, 9, 6);

  final SmsGateway _gateway;
  final SmsSettings _settings;
  final AccountResolver? Function() _accounts;
  final Set<String> Function() _existingIds;
  final SaveDetected _save;
  final Future<void> Function(String id) _delete;

  bool _busy = false;
  bool get isBusy => _busy;

  Future<FulizaPreview> preview() async {
    final messages =
        await _gateway.readInbox(senders: SmsParser.allSenders, since: since);
    final existing = _existingIds();
    final accounts = _accounts();
    final seen = <String>{};
    final items = <FulizaItem>[];
    for (final m in messages) {
      final parsed =
          SmsParser.parse(sender: m.sender, body: m.body, date: m.date);
      if (parsed == null || !parsed.kind.isFuliza) continue;
      final t = SmsImportService.toTransaction(parsed,
          simSlot: m.simSlot, accounts: accounts);
      final key = parsed.dedupeKey;
      final status = !seen.add(key)
          ? FulizaStatus.repeated
          : existing.contains(key)
              ? FulizaStatus.alreadyImported
              : (t.accountId == null || t.toAccountId == null)
                  ? FulizaStatus.needsReview
                  : FulizaStatus.eligible;
      items.add(FulizaItem(parsed, t, status));
    }
    return FulizaPreview(items, paymentsSaved: {
      for (final i in items)
        if (i.isDraw &&
            existing.contains(
                i.key.substring(0, i.key.length - '_FULIZA'.length)))
          i.key,
    });
  }

  Future<FulizaRunResult> importEligible(FulizaPreview preview) async {
    if (_busy) return const FulizaRunResult(error: 'Already running.');
    _busy = true;
    var created = 0, skipped = 0;
    try {
      final ids = [...await _settings.fulizaImportIds()];
      for (final item in preview.eligible) {
        final bool added;
        try {
          added = await _save(item.transaction, item.key);
        } on DataException catch (e) {
          return FulizaRunResult(
              done: created, skipped: skipped, error: e.message);
        }
        if (added) {
          ids.add(item.key);
          await _settings.setFulizaImportIds(ids);
          created++;
        } else {
          skipped++;
        }
        await _settings.addHandledKey(item.key);
      }
      return FulizaRunResult(done: created, skipped: skipped);
    } finally {
      _busy = false;
    }
  }

  /// Ids created by Fuliza imports in this profile and not undone yet.
  Future<List<String>> importedIds() => _settings.fulizaImportIds();

  Future<FulizaRunResult> undo() async {
    if (_busy) return const FulizaRunResult(error: 'Already running.');
    _busy = true;
    var deleted = 0;
    try {
      final remaining = [...await _settings.fulizaImportIds()];
      for (final id in [...remaining]) {
        try {
          await _delete(id);
        } on DataException catch (e) {
          return FulizaRunResult(done: deleted, error: e.message);
        }
        remaining.remove(id);
        await _settings.setFulizaImportIds(remaining);
        deleted++;
      }
      return FulizaRunResult(done: deleted);
    } finally {
      _busy = false;
    }
  }
}
