import '../models/transaction_model.dart';

/// What kind of mobile-money transaction an SMS describes.
enum SmsTransactionKind {
  /// Paid a merchant (Buy Goods / Till) or a Paybill.
  payment,

  /// Sent money to a person.
  sent,

  /// Received money (from a person or a business, e.g. salary).
  received,

  /// Withdrew cash at an agent.
  withdrawal,

  /// Deposited cash at an agent.
  deposit,

  /// Bought airtime or a data bundle.
  airtime,
}

/// Everything the parser could read from one transaction SMS.
///
/// This lives only on the device. What actually gets saved to Firestore is
/// the [TransactionModel] built from it by `SmsImportService`.
class SmsTransaction {
  const SmsTransaction({
    required this.source,
    required this.kind,
    required this.amount,
    required this.reference,
    required this.date,
    required this.maskedText,
    this.counterparty,
    this.phone,
    this.account,
    this.fee,
  });

  final TransactionSource source;
  final SmsTransactionKind kind;

  /// Always positive; [kind] decides whether it's money in or out.
  final double amount;

  /// The transaction code, e.g. "SJK3ABC123". Unique per transaction, so it
  /// is what duplicate prevention is based on.
  final String reference;

  /// When the SMS arrived (the phone's timestamp for the message).
  final DateTime date;

  /// Merchant, recipient, sender or agent, tidied up (e.g. "Naivas").
  final String? counterparty;

  /// The other party's phone number, if the SMS included one.
  final String? phone;

  /// Paybill account number, if any.
  final String? account;

  /// Transaction cost charged by the provider, if the SMS mentioned it.
  final double? fee;

  /// The original SMS with long digit runs (phone / account numbers) masked.
  final String maskedText;

  /// Savings products whose name appears as the other party, e.g.
  /// "Ksh500.00 sent to ZIIDI" or "received Ksh500.00 from ZIIDI".
  /// Matched against the upper-cased name with spaces and dashes removed.
  static const savingsProducts = ['ZIIDI', 'MSHWARI', 'LOCKSAVINGS'];

  /// True when the other party is one of the [savingsProducts].
  bool get isSavingsProduct {
    final name =
        (counterparty ?? '').toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
    return savingsProducts.any(name.contains);
  }

  /// How PennyWise records it:
  /// * cash withdrawal / deposit at an agent: a transfer between the
  ///   mobile-money account and Cash, not spending or income;
  /// * money sent to / received from a savings product: a savings
  ///   contribution / withdrawal;
  /// * anything else received: income; anything else paid or sent: expense.
  TransactionType get type => switch (kind) {
        SmsTransactionKind.withdrawal ||
        SmsTransactionKind.deposit =>
          TransactionType.transfer,
        SmsTransactionKind.received when isSavingsProduct =>
          TransactionType.savingsWithdrawal,
        SmsTransactionKind.received => TransactionType.income,
        SmsTransactionKind.payment ||
        SmsTransactionKind.sent when isSavingsProduct =>
          TransactionType.savingsContribution,
        _ => TransactionType.expense,
      };

  /// Unique per real-world transaction: source + transaction code.
  /// Used as the Firestore document id, e.g. "mpesa_SJK3ABC123".
  String get dedupeKey => '${source.name}_$reference';
}
