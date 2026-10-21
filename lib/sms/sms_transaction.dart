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
  airtime;

  /// Money in or money out, as PennyWise records it.
  TransactionType get type => switch (this) {
        SmsTransactionKind.received ||
        SmsTransactionKind.deposit =>
          TransactionType.income,
        _ => TransactionType.expense,
      };
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

  TransactionType get type => kind.type;

  /// Unique per real-world transaction: source + transaction code.
  /// Used as the Firestore document id, e.g. "mpesa_SJK3ABC123".
  String get dedupeKey => '${source.name}_$reference';
}
