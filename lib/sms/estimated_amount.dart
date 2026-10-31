import '../models/transaction_model.dart';
import '../utils/formatters.dart';

/// A card payment made in another currency (e.g. USD) is saved in KES at
/// that day's market rate, marked in its note as estimated until the user
/// keeps or corrects it from their statement (the bank's card rate and fee
/// usually differ a little).
class EstimatedAmount {
  EstimatedAmount._();

  static const prefix = 'Estimated amount:';
  static const _checked = 'Card payment of';

  /// "Estimated amount: USD 20.00 at 129.20 KES per USD (market rate on
  /// 31 Oct 2026). Equity's card rate may differ: check your statement."
  static String note(
    String currency,
    double foreign,
    double rate,
    DateTime day,
  ) =>
      '$prefix $currency ${foreign.toStringAsFixed(2)} at '
      '${rate.toStringAsFixed(2)} KES per $currency (market rate on '
      "${Formatters.shortDate(day)}). Equity's card rate may differ: check "
      'your statement.';

  /// Whether [t] still has an estimated amount.
  static bool isEstimated(TransactionModel t) =>
      t.note?.startsWith(prefix) ?? false;

  /// "USD 20.00" from an estimated note, or null.
  static String? foreignAmount(TransactionModel t) {
    final note = t.note;
    if (note == null || !note.startsWith(prefix)) return null;
    return RegExp(r'^[A-Z]{3} [\d.]+').firstMatch(
      note.substring(prefix.length).trim(),
    )?.group(0);
  }

  /// The note once the user kept or corrected the amount.
  static String checkedNote(TransactionModel t, {required bool corrected}) {
    final foreign = foreignAmount(t) ?? 'another currency';
    return '$_checked $foreign. '
        '${corrected ? 'Amount from statement.' : 'Market-rate estimate kept.'}';
  }

  /// [t] with its KES amount and the [note] replaced.
  static TransactionModel withAmount(
    TransactionModel t,
    double amount,
    String note,
  ) => TransactionModel(
    id: t.id,
    description: t.description,
    amount: amount,
    type: t.type,
    categoryId: t.categoryId,
    date: t.date,
    note: note,
    source: t.source,
    reference: t.reference,
    smsText: t.smsText,
    account: t.account,
    toAccount: t.toAccount,
    fee: t.fee,
    interest: t.interest,
    refundOf: t.refundOf,
    accountId: t.accountId,
    toAccountId: t.toAccountId,
    simSlot: t.simSlot,
  );
}
