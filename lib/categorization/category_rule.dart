import '../models/transaction_model.dart';
import '../sms/sms_parser.dart';
import '../sms/sms_transaction.dart';
import 'merchant_key.dart';

/// A category the user chose for a merchant, remembered so the next
/// transaction from the same merchant gets it automatically.
///
/// Stored at `users/{uid}/categoryRules/{key}`; [key] is the document id.
class CategoryRule {
  const CategoryRule({
    required this.key,
    required this.categoryId,
    required this.type,
    this.count = 1,
    this.label,
  });

  /// See [CategoryRule.keyFor].
  final String key;
  final String categoryId;

  /// The rule only applies to transactions of this type (expense or income).
  final TransactionType type;

  /// How many times the user has chosen this.
  final int count;

  /// The merchant name as shown to the user (e.g. "Lilies Supermarket"),
  /// for the rules list. Not used for matching.
  final String? label;

  /// Rules are learned and applied only for these types.
  static bool learnable(TransactionType type) =>
      type == TransactionType.expense || type == TransactionType.income;

  /// The key for a detected SMS transaction, or null if it has no usable
  /// merchant name.
  ///
  /// `OUT:LILIES_SUPERMARKET`, or with a Paybill account
  /// `OUT:KPLC_PREPAID:54XXXXX789`; `IN:` for money received. Direction is
  /// part of the key so that "sent to X" and "received from X" learn
  /// separately. Account digits are masked exactly as stored, so a key from
  /// a new SMS equals the key from the stored copy of an older one.
  static String? keyFor(SmsTransaction t) {
    final name = MerchantKey.normalize(t.counterparty ?? '');
    if (name.isEmpty) return null;
    final direction = t.type.isMoneyIn ? 'IN' : 'OUT';
    final account = t.account == null
        ? ''
        : ':${MerchantKey.normalize(SmsParser.maskDigits(t.account!).replaceAll('*', 'X'))}';
    final key = '$direction:$name$account'
        .replaceAll(' ', '_')
        .replaceAll(RegExp(r'[^A-Z0-9_:X-]'), '');
    return key.length > 120 ? key.substring(0, 120) : key;
  }

  /// The key for a stored transaction, by re-reading its saved (masked) SMS.
  /// Null for manual entries.
  static String? keyForStored(TransactionModel t) {
    final sms = t.smsText;
    if (sms == null || !t.isDetected) return null;
    final parsed = SmsParser.parse(
      sender: t.source == TransactionSource.airtel ? 'AIRTELMONEY' : 'MPESA',
      body: sms,
      date: t.date,
    );
    return parsed == null ? null : keyFor(parsed);
  }
}
