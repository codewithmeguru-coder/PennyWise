/// Whether money came in or went out.
enum TransactionType { income, expense }

/// Where a transaction came from.
///
/// [manual] is anything the user typed in. The others were detected
/// automatically from a mobile-money SMS on Android.
enum TransactionSource {
  manual,
  mpesa,
  airtel;

  /// Name shown in the UI, e.g. "M-Pesa".
  String get label => switch (this) {
        TransactionSource.manual => 'Manual',
        TransactionSource.mpesa => 'M-Pesa',
        TransactionSource.airtel => 'Airtel Money',
      };
}

/// A single income or expense entry.
///
/// Kept deliberately plain (no Firebase types); conversion to and from a
/// Firestore document lives in `FirestoreTransactionRepository`.
class TransactionModel {
  const TransactionModel({
    this.id = '',
    required this.description,
    required this.amount,
    required this.type,
    required this.categoryId,
    required this.date,
    this.note,
    this.source = TransactionSource.manual,
    this.reference,
    this.smsText,
  });

  /// Firestore document id. Empty for a transaction that hasn't been saved.
  final String id;
  final String description;

  /// Always stored as a positive number; [type] decides the sign.
  final double amount;
  final TransactionType type;
  final String categoryId;
  final DateTime date;
  final String? note;

  /// Manual entry, or the mobile-money service it was detected from.
  final TransactionSource source;

  /// The M-Pesa / Airtel transaction code (e.g. "SJK3ABC123"). Only set for
  /// detected transactions.
  final String? reference;

  /// The original SMS (with phone numbers masked), kept for checking what
  /// the parser read. Only set for detected transactions.
  final String? smsText;

  bool get isExpense => type == TransactionType.expense;
  bool get isIncome => type == TransactionType.income;
  bool get isDetected => source != TransactionSource.manual;

  /// A copy with [id] replaced (used when a repository assigns one).
  TransactionModel withId(String id) => TransactionModel(
        id: id,
        description: description,
        amount: amount,
        type: type,
        categoryId: categoryId,
        date: date,
        note: note,
        source: source,
        reference: reference,
        smsText: smsText,
      );
}
