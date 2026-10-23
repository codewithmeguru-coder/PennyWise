import 'transaction_model.dart';

/// The one place PennyWise turns transactions into money totals.
///
/// Every screen (dashboard, budgets, charts) reads its numbers from here, so
/// they always agree. The rules, per [TransactionType]:
///
/// | Type                 | Income | Spending          | Available        | Savings |
/// | -------------------- | ------ | ----------------- | ---------------- | ------- |
/// | income               | +amount|                   | +amount          |         |
/// | expense              |        | +amount           | -amount          |         |
/// | transfer             |        |                   | 0 (moves between accounts) |  |
/// | savingsContribution  |        |                   | -amount          | +amount |
/// | savingsWithdrawal    |        |                   | +amount          | -amount |
/// | refund               |        | -amount (its category) | +amount     |         |
/// | debtRepayment        |        | +interest         | -amount          |         |
///
/// A [TransactionModel.fee] is always spending (category "fees") and always
/// leaves available money, whatever the type.
///
/// All sums are done in whole cents, so 0.1 + 0.2 is exactly 0.30.
class Ledger {
  Ledger._({
    required this.incomeCents,
    required this.expenseCents,
    required this.feeCents,
    required this.interestCents,
    required this.refundCents,
    required this.debtPrincipalCents,
    required this.savingsInCents,
    required this.savingsOutCents,
    required this.transferCents,
    required this.categoryCents,
    required this.accountCents,
    required this.accountIdCents,
    required this.transactionCount,
  });

  /// Totals for [transactions]. Pass one month's transactions for monthly
  /// figures, or all of them for balances.
  factory Ledger.of(Iterable<TransactionModel> transactions) {
    var income = 0, expense = 0, fees = 0, interest = 0, refunds = 0;
    var principal = 0, savingsIn = 0, savingsOut = 0, transfers = 0;
    var count = 0;
    final categories = <String, int>{};
    final accounts = <Account?, int>{};
    final byId = <String?, int>{};

    void move(Account? account, int cents) =>
        accounts.update(account, (c) => c + cents, ifAbsent: () => cents);
    // The same movements, by the user's own account ids ("mpesa-sim1",
    // "ziidi-sim2", ...). Null collects transactions without an account id
    // (older ones, or SIM unknown). [toAccountId] is the other side: the
    // receiving account of a transfer, the savings account of a savings
    // contribution / withdrawal, or the loan account of a debt repayment.
    void moveId(String? id, int cents) =>
        byId.update(id, (c) => c + cents, ifAbsent: () => cents);
    void spend(String category, int cents) =>
        categories.update(category, (c) => c + cents, ifAbsent: () => cents);

    for (final t in transactions) {
      count++;
      final cents = toCents(t.amount);
      final account = t.effectiveAccount;
      switch (t.type) {
        case TransactionType.income:
          income += cents;
          move(account, cents);
          moveId(t.accountId, cents);
        case TransactionType.expense:
          expense += cents;
          spend(t.categoryId, cents);
          move(account, -cents);
          moveId(t.accountId, -cents);
        case TransactionType.transfer:
          transfers += cents;
          move(account, -cents);
          move(t.toAccount, cents);
          moveId(t.accountId, -cents);
          moveId(t.toAccountId, cents);
        case TransactionType.savingsContribution:
          savingsIn += cents;
          move(account, -cents);
          move(Account.savings, cents);
          moveId(t.accountId, -cents);
          if (t.toAccountId != null) moveId(t.toAccountId, cents);
        case TransactionType.savingsWithdrawal:
          savingsOut += cents;
          move(Account.savings, -cents);
          move(account, cents);
          if (t.toAccountId != null) moveId(t.toAccountId, -cents);
          moveId(t.accountId, cents);
        case TransactionType.refund:
          refunds += cents;
          spend(t.categoryId, -cents);
          move(account, cents);
          moveId(t.accountId, cents);
        case TransactionType.debtRepayment:
          // Interest can't be more than the repayment itself.
          final part = toCents(t.interest ?? 0).clamp(0, cents);
          interest += part;
          principal += cents - part;
          if (part > 0) spend(t.categoryId, part);
          move(account, -cents);
          moveId(t.accountId, -cents);
          // The whole repayment reduces what is owed on the loan account.
          if (t.toAccountId != null) moveId(t.toAccountId, cents);
      }
      final fee = toCents(t.fee ?? 0);
      if (fee > 0) {
        fees += fee;
        spend(feesCategory, fee);
        move(account, -fee);
        moveId(t.accountId, -fee);
      }
    }

    return Ledger._(
      incomeCents: income,
      expenseCents: expense,
      feeCents: fees,
      interestCents: interest,
      refundCents: refunds,
      debtPrincipalCents: principal,
      savingsInCents: savingsIn,
      savingsOutCents: savingsOut,
      transferCents: transfers,
      categoryCents: Map.unmodifiable(categories),
      accountCents: Map.unmodifiable(accounts),
      accountIdCents: Map.unmodifiable(byId),
      transactionCount: count,
    );
  }

  /// Category id that fees are reported under.
  static const feesCategory = 'fees';

  final int incomeCents;
  final int expenseCents;
  final int feeCents;
  final int interestCents;
  final int refundCents;
  final int debtPrincipalCents;
  final int savingsInCents;
  final int savingsOutCents;
  final int transferCents;

  /// Net spending per category (expenses + fees + interest − refunds).
  /// May hold zero or negative values, e.g. a refund in a month with no
  /// matching purchase; [spendingByCategory] leaves those out.
  final Map<String, int> categoryCents;

  /// Net change per account. The `null` key collects older manual
  /// transactions that were saved before accounts existed.
  final Map<Account?, int> accountCents;

  /// Net change per user account id ("mpesa-sim1", ...); the null key holds
  /// transactions with no account id. Savings and loan accounts only move
  /// when a transaction names them in `toAccountId`.
  final Map<String?, int> accountIdCents;

  /// Net change of the user's account [id]; null = not assigned to one.
  double balanceOfId(String? id) => fromCents(accountIdCents[id] ?? 0);

  final int transactionCount;

  /// Money earned.
  double get income => fromCents(incomeCents);

  /// What it cost you: expenses + fees + interest − refunds.
  double get spending => fromCents(spendingCents);
  int get spendingCents =>
      expenseCents + feeCents + interestCents - refundCents;

  /// Income − spending. Savings and transfers don't change it.
  double get net => fromCents(incomeCents - spendingCents);

  /// Money moved into savings minus money taken out.
  double get netSaved => fromCents(savingsInCents - savingsOutCents);

  /// Loan principal repaid: leaves your accounts but isn't spending.
  double get debtPrincipal => fromCents(debtPrincipalCents);

  double get fees => fromCents(feeCents);
  double get refunds => fromCents(refundCents);

  /// Money in savings (over the transactions given).
  double get savingsBalance => fromCents(accountCents[Account.savings] ?? 0);

  /// Money you can spend: every account except savings, including older
  /// transactions that have no account.
  double get available => fromCents(accountCents.entries
      .where((e) => e.key != Account.savings)
      .fold(0, (sum, e) => sum + e.value));

  /// Balance change of one account; [Account.savings] equals
  /// [savingsBalance]. `null` = transactions with no account.
  double balanceOf(Account? account) => fromCents(accountCents[account] ?? 0);

  /// Categories with net spending above zero, largest first.
  List<MapEntry<String, int>> get spendingByCategory => categoryCents.entries
      .where((e) => e.value > 0)
      .toList()
    ..sort((a, b) => b.value.compareTo(a.value));

  static int toCents(double amount) => (amount * 100).round();
  static double fromCents(int cents) => cents / 100;
}
