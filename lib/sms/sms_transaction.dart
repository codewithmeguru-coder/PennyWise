import '../categorization/merchant_key.dart';
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

  /// Fuliza (Safaricom's overdraft) lent money to complete a payment:
  /// "Fuliza M-PESA amount is Ksh 50.00. Access Fee charged Ksh 0.50."
  /// The SMS uses the same code as the payment it funded.
  fulizaDraw,

  /// M-Pesa balance used to repay Fuliza: "Ksh 300.00 from your M-PESA has
  /// been used to fully pay your outstanding Fuliza M-PESA."
  fulizaRepayment;

  bool get isFuliza => this == fulizaDraw || this == fulizaRepayment;
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

  /// Savings products, as the exact other party in the M-Pesa sentence:
  /// "Ksh1.00 sent to ZIIDI on …" / "received Ksh500.00 from ZIIDI on …".
  /// Compared with spaces and dashes removed ("M-Shwari" = "MSHWARI").
  static const savingsProducts = {'ZIIDI', 'MSHWARI', 'LOCKSAVINGS'};

  /// True when the other party is exactly one of the [savingsProducts]. Not
  /// "contains": a name like "Ziidi Sacco" or an advert mentioning Ziidi
  /// elsewhere in the SMS must not count.
  bool get isSavingsProduct =>
      savingsProducts.contains(MerchantKey.compact(counterparty ?? ''));

  /// How PennyWise records it:
  /// * cash withdrawal / deposit at an agent: a transfer between the
  ///   mobile-money account and Cash, not spending or income;
  /// * money sent to / received from a savings product: a savings
  ///   contribution / withdrawal;
  /// * anything else received: income; anything else paid or sent: expense.
  TransactionType get type => switch (kind) {
        // Borrowed money arriving in M-Pesa from the Fuliza loan account:
        // a transfer, not income. The access fee is spending (fee).
        SmsTransactionKind.fulizaDraw => TransactionType.transfer,
        SmsTransactionKind.fulizaRepayment => TransactionType.debtRepayment,
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
  ///
  /// A Fuliza draw shares its code with the payment it funded, so it gets
  /// its own key ("mpesa_SJK3ABC123_FULIZA"); otherwise the payment and the
  /// loan would block each other as "duplicates".
  String get dedupeKey => kind == SmsTransactionKind.fulizaDraw
      ? '${source.name}_${reference}_FULIZA'
      : '${source.name}_$reference';
}
