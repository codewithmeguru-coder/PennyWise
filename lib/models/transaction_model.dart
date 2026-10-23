/// What a transaction is, for accounting purposes.
///
/// Only [income] and [expense] change what you earned or spent. The others
/// move money around (between your accounts, into or out of savings) or
/// correct earlier spending, and the `Ledger` treats each one accordingly.
///
/// Stored in Firestore as [wireName]. Documents written before these kinds
/// existed only ever contain "income" or "expense", which still read back
/// exactly as before.
enum TransactionType {
  /// Money earned: salary, money received, gifts.
  income('income', 'Income'),

  /// Money spent on goods or services.
  expense('expense', 'Expense'),

  /// Money moved between two of your own accounts, e.g. a cash withdrawal
  /// (M-Pesa to Cash). Neither income nor spending.
  transfer('transfer', 'Transfer'),

  /// Money put into savings. Not spending: it is still yours.
  savingsContribution('savings_contribution', 'To savings'),

  /// Money taken out of savings. Not income: you already had it.
  savingsWithdrawal('savings_withdrawal', 'From savings'),

  /// Money given back for an earlier purchase. Reduces spending in its
  /// category instead of counting as income.
  refund('refund', 'Refund'),

  /// Paying back a loan (e.g. Fuliza). Only the interest part is spending;
  /// the principal repays money you already counted when you spent it.
  debtRepayment('debt_repayment', 'Debt repayment');

  const TransactionType(this.wireName, this.label);

  /// The value stored in Firestore.
  final String wireName;

  /// Name shown in the UI.
  final String label;

  /// The type for a stored value, or null if this version doesn't know it.
  static TransactionType? fromWire(String? value) {
    for (final type in values) {
      if (type.wireName == value) return type;
    }
    return null;
  }

  /// True when the amount comes into the account it is recorded against.
  bool get isMoneyIn =>
      this == income || this == refund || this == savingsWithdrawal;
}

/// One of the places your money can be. A fixed list for now.
enum Account {
  mpesa('mpesa', 'M-Pesa'),
  airtelMoney('airtel_money', 'Airtel Money'),
  cash('cash', 'Cash'),
  bank('bank', 'Bank'),

  /// Money set aside. Only savings contributions and withdrawals move money
  /// in and out of it, so it is never picked as a normal account.
  savings('savings', 'Savings');

  const Account(this.wireName, this.label);

  final String wireName;
  final String label;

  static Account? fromWire(String? value) {
    for (final account in values) {
      if (account.wireName == value) return account;
    }
    return null;
  }

  /// The accounts a user can pick for spending, income and transfers.
  static const List<Account> spendable = [mpesa, airtelMoney, cash, bank];
}

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

/// A single money movement: income, expense, transfer, savings, refund or
/// debt repayment.
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
    this.account,
    this.toAccount,
    this.fee,
    this.interest,
    this.refundOf,
  });

  /// Firestore document id. Empty for a transaction that hasn't been saved.
  final String id;
  final String description;

  /// Always stored as a positive number; [type] decides what it means.
  /// Does not include [fee].
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

  /// The account the money left (expense, transfer, savings contribution,
  /// debt repayment) or arrived in (income, refund, savings withdrawal).
  /// Null on transactions saved before accounts existed; see
  /// [effectiveAccount].
  final Account? account;

  /// For a [TransactionType.transfer]: the account the money went to.
  final Account? toAccount;

  /// Charge paid to the provider on top of [amount] (e.g. the M-Pesa
  /// transaction cost), taken from [account]. Counted as spending.
  final double? fee;

  /// For a [TransactionType.debtRepayment]: how much of [amount] was
  /// interest or charges. Null when unknown, in which case the whole
  /// repayment is treated as principal.
  final double? interest;

  /// For a [TransactionType.refund]: the id of the purchase it refunds, if
  /// the user linked one.
  final String? refundOf;

  bool get isExpense => type == TransactionType.expense;
  bool get isIncome => type == TransactionType.income;
  bool get isDetected => source != TransactionSource.manual;

  /// [account], or for older transactions without one, the account implied
  /// by where they were detected (an M-Pesa SMS means M-Pesa). Null for
  /// older manual entries.
  Account? get effectiveAccount =>
      account ??
      switch (source) {
        TransactionSource.mpesa => Account.mpesa,
        TransactionSource.airtel => Account.airtelMoney,
        TransactionSource.manual => null,
      };

  /// A copy with only the category changed.
  TransactionModel withCategory(String categoryId) => TransactionModel(
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
        account: account,
        toAccount: toAccount,
        fee: fee,
        interest: interest,
        refundOf: refundOf,
      );

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
        account: account,
        toAccount: toAccount,
        fee: fee,
        interest: interest,
        refundOf: refundOf,
      );
}
