import '../models/ledger.dart';
import 'account_balances.dart';
import 'money_account.dart';

/// How close a loan is to its limit.
enum LoanLimitLevel {
  /// Under [LoanLimit.warnShare] of the limit used.
  ok,

  /// At least [LoanLimit.warnShare] used, some still available.
  near,

  /// Nothing left to borrow.
  reached,
}

/// A loan account's limit (e.g. one SIM's Fuliza), what is owed on it and
/// what is still available. Each SIM's loan has its own limit; they are
/// never added together.
class LoanLimit {
  const LoanLimit._(this.account, this.limit, this.owed);

  /// Warn once this share of the limit is used (80%).
  static const warnShare = 0.8;

  final MoneyAccount account;

  /// The limit the user entered.
  final double limit;

  /// What is owed now (never negative: a credit counts as nothing owed).
  final double owed;

  /// For a loan account with a limit set: its limit, owed and available.
  /// Null for other accounts or when no limit is set.
  static LoanLimit? of(AccountBalance balance) {
    final a = balance.account;
    final limit = a.creditLimit;
    if (a.kind != AccountKind.loan || limit == null || limit <= 0) return null;
    final owed = balance.owed > 0 ? balance.owed : 0.0;
    return LoanLimit._(a, limit, owed);
  }

  /// Limits for every loan account in [balances] that has one.
  static List<LoanLimit> all(Iterable<AccountBalance> balances) => [
    for (final b in balances) ?of(b),
  ];

  /// Limit minus owed, to the cent; 0 when the limit is used up (or owed
  /// is above the limit, e.g. the limit was lowered).
  double get available {
    final cents = Ledger.toCents(limit) - Ledger.toCents(owed);
    return cents > 0 ? Ledger.fromCents(cents) : 0;
  }

  /// Share of the limit used, from 0 (may pass 1 if owed is above it).
  double get usedShare => owed / limit;

  LoanLimitLevel get level => available <= 0
      ? LoanLimitLevel.reached
      : usedShare >= warnShare
      ? LoanLimitLevel.near
      : LoanLimitLevel.ok;
}
