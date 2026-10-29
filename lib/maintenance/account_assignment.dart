import '../accounts/account_balances.dart';
import '../accounts/account_repository.dart';
import '../accounts/money_account.dart';
import '../models/ledger.dart';
import '../models/transaction_model.dart';

/// Giving SMS records with no account their account: who can get one, which
/// account the SIM says, and exactly how each account card would change.
///
/// Only the account (and the SIM, when known) is set: never the category,
/// type, amount or date. Moves that need two accounts (transfers, savings,
/// debt repayments) aren't assigned here; they are edited in the form,
/// which asks for both sides.
class AccountAssignment {
  AccountAssignment._();

  /// Types with one account side, which a single account id completes.
  static const singleSided = {
    TransactionType.income,
    TransactionType.expense,
    TransactionType.refund,
  };

  /// An SMS record with no account.
  static bool missingAccount(TransactionModel t) =>
      t.isDetected && t.accountId == null && t.toAccountId == null;

  /// [missingAccount] and assignable here (one account side).
  static bool assignable(TransactionModel t) =>
      missingAccount(t) && singleSided.contains(t.type);

  /// The SMS records with no account, newest first.
  static List<TransactionModel> pending(List<TransactionModel> all) =>
      all.where(missingAccount).toList()
        ..sort((a, b) => b.date.compareTo(a.date));

  /// The wallet of the SIM the record came to, when the SIM is known.
  static MoneyAccount? forKnownSim(
    TransactionModel t,
    AccountResolver accounts,
  ) {
    if (t.simSlot == null) return null;
    return accounts.forSim(
      t.simSlot,
      AccountKind.mobileMoney,
      provider: t.source == TransactionSource.airtel
          ? AccountProvider.airtel
          : AccountProvider.safaricom,
    );
  }

  /// How each account card changes if [after] replace the records with the
  /// same ids in [all]: the card balance after minus before, per account,
  /// only where it changes. The card's own rules decide (starting balance
  /// date, SIM evidence), so a record before an account's starting balance,
  /// or one already counted through its SIM, changes nothing.
  static Map<MoneyAccount, double> impact(
    List<MoneyAccount> accounts,
    List<TransactionModel> all,
    Iterable<TransactionModel> after,
  ) {
    final replaced = {for (final t in after) t.id: t};
    final existing = {for (final t in all) t.id};
    // Changed records replace their old selves; new ones are added.
    final next = [
      for (final t in all) replaced[t.id] ?? t,
      for (final t in after)
        if (!existing.contains(t.id)) t,
    ];
    final out = <MoneyAccount, double>{};
    for (final a in accounts) {
      final before = Ledger.toCents(AccountBalance.of(a, all).computed);
      final now = Ledger.toCents(AccountBalance.of(a, next).computed);
      if (now != before) out[a] = Ledger.fromCents(now - before);
    }
    return out;
  }

  /// How each account card's displayed balance changes (what the card and
  /// Home show), per account, only where it changes. Unlike [impact]: a
  /// card with no starting balance shows its newest SMS balance plus what
  /// came after it, so records older than that message don't move it.
  static Map<MoneyAccount, double> cardChange(
    List<MoneyAccount> accounts,
    List<TransactionModel> all,
    Iterable<TransactionModel> after,
  ) {
    final replaced = {for (final t in after) t.id: t};
    final existing = {for (final t in all) t.id};
    final next = [
      for (final t in all) replaced[t.id] ?? t,
      for (final t in after)
        if (!existing.contains(t.id)) t,
    ];
    final out = <MoneyAccount, double>{};
    for (final a in accounts) {
      final before = Ledger.toCents(AccountBalance.of(a, all).shown);
      final now = Ledger.toCents(AccountBalance.of(a, next).shown);
      if (now != before) out[a] = Ledger.fromCents(now - before);
    }
    return out;
  }
}
