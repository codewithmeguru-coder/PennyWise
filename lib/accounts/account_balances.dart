import '../models/ledger.dart';
import '../models/transaction_model.dart';
import 'money_account.dart';

/// What PennyWise knows about one account's balance.
class AccountBalance {
  const AccountBalance({
    required this.account,
    required this.computed,
    required this.hasOpening,
    this.reported,
    this.reportedAt,
  });

  final MoneyAccount account;

  /// Opening balance (if set) plus this account's transactions since then.
  final double computed;

  /// The user entered a starting balance, so [computed] can be trusted as
  /// far as the recorded transactions go.
  final bool hasOpening;

  /// For M-Pesa: the balance stated in the newest SMS for this account
  /// ("New M-PESA balance is Ksh 1,234.00"). This is the phone company's
  /// figure, so it's shown in preference to [computed].
  final double? reported;
  final DateTime? reportedAt;

  /// The figure to show: the stated SMS balance when there is one,
  /// otherwise the computed one.
  double get shown => reported ?? computed;

  /// True when [shown] is PennyWise's own calculation without a starting
  /// balance, so it may be off because earlier history is missing.
  bool get isEstimate => reported == null && !hasOpening;

  /// The stated SMS balance and PennyWise's figure differ by more than a
  /// shilling (missing or unreadable messages, Fuliza not yet imported...).
  bool get differs =>
      reported != null && hasOpening && (reported! - computed).abs() > 1;

  /// Balances for every account in [accounts] from [transactions].
  static List<AccountBalance> forAll(
    List<MoneyAccount> accounts,
    List<TransactionModel> transactions,
  ) =>
      [for (final a in accounts) of(a, transactions)];

  static AccountBalance of(MoneyAccount a, List<TransactionModel> txs) {
    final since = a.openingDate;
    final relevant = txs.where((t) =>
        (t.accountId == a.id || t.toAccountId == a.id) &&
        (since == null || !t.date.isBefore(since)));
    final ledger = Ledger.of(relevant);
    final computed = Ledger.fromCents(Ledger.toCents(a.openingBalance ?? 0) +
        Ledger.toCents(ledger.balanceOfId(a.id)));

    double? reported;
    DateTime? reportedAt;
    if (a.kind == AccountKind.mobileMoney) {
      // Newest SMS for this account that states the balance, from the
      // starting date on (an older one would undo a fresh start).
      for (final t in txs) {
        // txs are newest first (TransactionStore order).
        if (t.accountId != a.id && t.toAccountId != a.id) continue;
        if (since != null && t.date.isBefore(since)) break;
        final stated = statedBalance(t.smsText);
        if (stated != null) {
          reported = stated;
          reportedAt = t.date;
          break;
        }
      }
    }
    return AccountBalance(
      account: a,
      computed: computed,
      hasOpening: a.openingBalance != null,
      reported: reported,
      reportedAt: reportedAt,
    );
  }

  /// Home's totals from the account cards: money available (M-Pesa, banks,
  /// cash) and savings, from active accounts only. Used once any of them
  /// (other than loans) has a starting balance, e.g. after "Start over";
  /// one without (an account added or shown again later) adds its card's
  /// estimate. Until then null, and Home adds up the whole history.
  static ({double available, double savings})? totals(
    List<MoneyAccount> active,
    List<TransactionModel> transactions,
  ) {
    final cards = forAll(
        active.where((a) => a.kind != AccountKind.loan).toList(),
        transactions);
    if (!cards.any((b) => b.hasOpening)) return null;
    var available = 0, savings = 0; // cents
    for (final b in cards) {
      if (b.account.kind == AccountKind.savings) {
        savings += Ledger.toCents(b.shown);
      } else {
        available += Ledger.toCents(b.shown);
      }
    }
    return (
      available: Ledger.fromCents(available),
      savings: Ledger.fromCents(savings),
    );
  }

  static final _balance = RegExp(
      r'(?:new\s+m-?pesa\s+balance\s+is|your\s+m-?pesa\s+balance\s+is)\s*'
      r'(?:ksh)?\s?([\d,]+(?:\.\d{1,2})?)',
      caseSensitive: false);

  /// The M-Pesa balance an SMS states, or null.
  static double? statedBalance(String? sms) {
    if (sms == null) return null;
    final m = _balance.firstMatch(sms);
    if (m == null) return null;
    return double.tryParse(m.group(1)!.replaceAll(',', ''));
  }
}
