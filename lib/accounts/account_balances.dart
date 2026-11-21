import '../models/fuliza_link.dart';
import '../models/ledger.dart';
import '../models/transaction_model.dart';
import 'money_account.dart';

/// How far an account's balance can be trusted.
enum BalanceStatus {
  /// Has a starting balance, and the newest balance stated by an SMS since
  /// then agrees with PennyWise's calculation.
  verified,

  /// Has a starting balance, but the newest SMS balance since then
  /// disagrees: something is missing, duplicated or on the wrong account.
  mismatch,

  /// Has a starting balance; no SMS balance since then to check it with.
  anchored,

  /// No starting balance, but an SMS stated the balance: shown as that
  /// figure plus what happened after it.
  fromSms,

  /// No starting balance and no SMS balance: only recorded history, which
  /// may be incomplete. Shown as an estimate.
  unverified,
}

/// What PennyWise knows about one account's balance.
///
/// The model, for every account:
/// - **Anchor:** the account's starting balance
///   ([MoneyAccount.openingBalance]) at [MoneyAccount.openingDate], a
///   verified figure at a point in time.
/// - **History:** the account's transactions dated at or after the anchor.
///   Earlier ones stay in the history and reports but never change the
///   balance again, so re-anchoring can't double count.
/// - **Calculated:** anchor + history ([computed]).
/// - **SMS evidence:** for M-Pesa, the newest message that states the
///   remaining balance ("New M-PESA balance is …", "Your M-PESA balance is
///   …") for that SIM. A message that only mentions an amount, a Fuliza
///   limit or a Fuliza total is not balance evidence.
/// - **Reconciliation:** the calculation is compared with that SMS at the
///   SMS's own time ([calculatedAtReport]); a difference is shown, never
///   silently applied.
///
/// Sign convention: for M-Pesa, bank, cash and savings a positive balance
/// is money held. For a loan (Fuliza) the balance is negative while money
/// is owed; [owed] gives the positive amount owed, which is what the app
/// shows. A Fuliza limit is neither.
class AccountBalance {
  const AccountBalance({
    required this.account,
    required this.computed,
    required this.hasOpening,
    this.reported,
    this.reportedAt,
    this.calculatedAtReport,
    this.afterReport = 0,
  });

  final MoneyAccount account;

  /// Starting balance (if set) plus this account's transactions since then.
  final double computed;

  /// The user entered a starting balance (the anchor).
  final bool hasOpening;

  /// For M-Pesa: the newest balance stated by an SMS for this account or
  /// SIM, after the anchor if there is one.
  final double? reported;
  final DateTime? reportedAt;

  /// With an anchor: what PennyWise calculated for the moment of
  /// [reportedAt], to compare with [reported].
  final double? calculatedAtReport;

  /// Movements on this account after [reportedAt].
  final double afterReport;

  BalanceStatus get status {
    if (hasOpening) {
      if (reported == null || calculatedAtReport == null) {
        return BalanceStatus.anchored;
      }
      return (reported! - calculatedAtReport!).abs() > 1
          ? BalanceStatus.mismatch
          : BalanceStatus.verified;
    }
    return reported != null ? BalanceStatus.fromSms : BalanceStatus.unverified;
  }

  /// The figure to show. With an anchor it is always the calculation (an SMS
  /// never silently replaces it); without one, the SMS figure plus what
  /// happened after it; otherwise the history alone, as an estimate.
  ///
  /// A loan (Fuliza) is the exception: M-Pesa states the whole outstanding
  /// amount in its Fuliza messages, so the newest one plus what happened
  /// after it is shown, anchor or not. The calculation is still compared
  /// with it ([status], [difference]).
  double get shown => shownFromSms
      ? Ledger.fromCents(
          Ledger.toCents(reported!) + Ledger.toCents(afterReport))
      : computed;

  /// The figure shown comes from an SMS (see [shown]).
  bool get shownFromSms =>
      reported != null &&
      (status == BalanceStatus.fromSms || account.kind == AccountKind.loan);

  /// For a loan: the amount owed (positive), from [shown].
  double get owed => -shown;

  /// SMS figure minus PennyWise's figure at the SMS's time, when they can be
  /// compared (an anchor and a newer SMS).
  double? get difference =>
      hasOpening && reported != null && calculatedAtReport != null
          ? Ledger.fromCents(
              Ledger.toCents(reported!) - Ledger.toCents(calculatedAtReport!))
          : null;

  /// No starting balance and no SMS: only history, which may be incomplete.
  bool get isEstimate => status == BalanceStatus.unverified;

  /// The SMS and PennyWise disagree (see [difference]).
  bool get differs => status == BalanceStatus.mismatch;

  /// Balances for every account in [accounts] from [transactions].
  static List<AccountBalance> forAll(
    List<MoneyAccount> accounts,
    List<TransactionModel> transactions,
  ) =>
      [for (final a in accounts) of(a, transactions)];

  /// [t] belongs to account [a]: by its account ids, or for a SIM's M-Pesa,
  /// an SMS from that SIM saved before accounts existed (SIM known, no
  /// account id).
  static bool belongs(MoneyAccount a, TransactionModel t) {
    if (t.accountId == a.id || t.toAccountId == a.id) return true;
    return a.kind == AccountKind.mobileMoney &&
        a.simSlot != null &&
        t.accountId == null &&
        t.toAccountId == null &&
        t.isDetected &&
        t.simSlot == a.simSlot &&
        t.effectiveAccount == a.legacy;
  }

  /// How [t] changes account [a], in cents.
  static int _delta(MoneyAccount a, TransactionModel t) {
    final ledger = Ledger.of([t]);
    if (t.accountId == a.id || t.toAccountId == a.id) {
      return Ledger.toCents(ledger.balanceOfId(a.id));
    }
    return Ledger.toCents(ledger.balanceOf(a.legacy));
  }

  static AccountBalance of(MoneyAccount a, List<TransactionModel> txs) {
    final since = a.openingDate;
    bool counts(TransactionModel t) =>
        belongs(a, t) && (since == null || !t.date.isBefore(since));

    var total = Ledger.toCents(a.openingBalance ?? 0);
    for (final t in txs) {
      if (counts(t)) total += _delta(a, t);
    }

    double? reported, calculatedAtReport;
    DateTime? reportedAt;
    var after = 0;
    if (a.kind == AccountKind.mobileMoney || a.kind == AccountKind.loan) {
      // Newest balance-bearing SMS for this account or SIM (for a loan, the
      // newest that states what is outstanding), from the anchor on (an
      // older one says nothing about the balance since then).
      final picked = _newestEvidence(a, [
        for (final t in txs)
          if (counts(t) && t.isDetected && _stated(a, t) != null) t,
      ]);
      if (picked != null) {
        final (evidence, cutoff) = picked;
        reported = _stated(a, evidence);
        reportedAt = evidence.date;
        var upTo = Ledger.toCents(a.openingBalance ?? 0);
        // The Fuliza loan that funded this very payment (same code, saved
        // as "<payment id>_FULIZA") is already in the balance its SMS
        // states, even when the loan SMS arrives a few seconds later.
        final fundedBy = '${evidence.id}${FulizaLinks.loanSuffix}';
        for (final t in txs) {
          if (!counts(t)) continue;
          final included = t.id == fundedBy &&
              t.type == TransactionType.transfer &&
              t.reference != null &&
              t.reference == evidence.reference;
          if (t.date.isAfter(cutoff) && !included) {
            after += _delta(a, t);
          } else {
            upTo += _delta(a, t);
          }
        }
        if (a.openingBalance != null) {
          calculatedAtReport = Ledger.fromCents(upTo);
        }
      }
    }
    return AccountBalance(
      account: a,
      computed: Ledger.fromCents(total),
      hasOpening: a.openingBalance != null,
      reported: reported,
      reportedAt: reportedAt,
      calculatedAtReport: calculatedAtReport,
      afterReport: Ledger.fromCents(after),
    );
  }

  /// Home's totals from the account cards: money available (M-Pesa, banks,
  /// cash) and savings, from active accounts (loans aren't money held).
  /// [unverified] counts accounts with neither a starting balance nor an
  /// SMS balance, and [mismatched] those whose SMS disagrees, so Home can
  /// say how far the total can be trusted. Null without such accounts; Home
  /// then shows its whole-history figure, labelled as such.
  static ({
    double available,
    double savings,
    int unverified,
    int mismatched,
  })? totals(
    List<MoneyAccount> active,
    List<TransactionModel> transactions,
  ) {
    final cards = forAll(
        active.where((a) => a.kind != AccountKind.loan).toList(),
        transactions);
    if (cards.isEmpty) return null;
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
      unverified: cards.where((b) => b.isEstimate).length,
      mismatched: cards.where((b) => b.differs).length,
    );
  }

  /// The newest balance stated by an SMS for account [a] (by account id, or
  /// its SIM), whatever its starting balance: what onboarding can offer as
  /// a starting point. Null without such a message.
  static ({double amount, DateTime at})? latestSmsBalance(
      MoneyAccount a, List<TransactionModel> txs) {
    if (a.kind != AccountKind.mobileMoney) return null;
    final picked = _newestEvidence(a, [
      for (final t in txs)
        if (t.isDetected && belongs(a, t) && statedBalance(t.smsText) != null)
          t,
    ]);
    if (picked == null) return null;
    final best = picked.$1;
    return (amount: statedBalance(best.smsText)!, at: best.date);
  }

  /// Balance SMS this close to the newest one may be out of order: messages
  /// sent seconds apart (e.g. money received, then the Fuliza repayment it
  /// paid for) can be saved with the same time, or even the wrong way round,
  /// because the network's timestamp has whole-second precision.
  static const sameMomentWindow = Duration(minutes: 2);

  /// The newest of [candidates] (balance-bearing SMS for account [a]) and
  /// the cutoff: movements after the cutoff are "after the SMS".
  ///
  /// Within [sameMomentWindow] of the newest, the order comes from the
  /// balances themselves: X follows Y when Y's balance plus X's own
  /// movement gives X's balance (Ksh300.00 - 278.26 = 21.74). The one that
  /// nothing follows is the latest, and every message in the window is
  /// already in its balance. If that doesn't settle it, the newest by time
  /// wins, and on an exact tie a Fuliza repayment (always sent after the
  /// money that paid it).
  static (TransactionModel, DateTime)? _newestEvidence(
    MoneyAccount a,
    List<TransactionModel> candidates,
  ) {
    if (candidates.isEmpty) return null;
    var newest = candidates.first;
    for (final t in candidates.skip(1)) {
      if (t.date.isAfter(newest.date) ||
          (t.date == newest.date &&
              t.type == TransactionType.debtRepayment &&
              newest.type != TransactionType.debtRepayment)) {
        newest = t;
      }
    }
    final window = [
      for (final t in candidates)
        if (newest.date.difference(t.date) <= sameMomentWindow) t,
    ];
    if (window.length < 2) return (newest, newest.date);

    int stated(TransactionModel t) => Ledger.toCents(_stated(a, t)!);
    bool follows(TransactionModel x, TransactionModel y) =>
        !identical(x, y) && stated(y) + _delta(a, x) == stated(x);
    final last = [
      for (final x in window)
        if (window.any((y) => follows(x, y)) &&
            !window.any((z) => follows(z, x)))
          x,
    ];
    if (last.length != 1) return (newest, newest.date);
    final latest = window
        .map((t) => t.date)
        .reduce((p, q) => q.isAfter(p) ? q : p);
    return (last.single, latest);
  }

  static final _balance = RegExp(
      r'(?:new\s+m-?pesa\s+balance\s+is|your\s+m-?pesa\s+balance\s+is)\s*'
      r'(?:ksh)?\s?([\d,]+(?:\.\d{1,2})?)',
      caseSensitive: false);

  /// What [t]'s SMS says account [a]'s balance is: the M-Pesa balance for a
  /// wallet, minus the Fuliza outstanding amount for a loan (owed money is
  /// negative). Null if it says neither.
  static double? _stated(MoneyAccount a, TransactionModel t) =>
      switch (a.kind) {
        AccountKind.mobileMoney => statedBalance(t.smsText),
        AccountKind.loan => switch (statedOutstanding(t.smsText)) {
            final owed? => owed == 0 ? 0.0 : -owed,
            null => null,
          },
        _ => null,
      };

  // "Total Fuliza M-PESA outstanding amount is Ksh278.26 due on …"
  static final _outstanding = RegExp(
      r'outstanding\s+amount\s+is\s*(?:ksh)?\s?([\d,]+(?:\.\d{1,2})?)',
      caseSensitive: false);
  // "… has been used to fully pay your outstanding Fuliza M-PESA."
  static final _fullyPaid = RegExp(
      r'used\s+to\s+fully\s+pay\s+your\s+outstanding\s+fuliza',
      caseSensitive: false);

  /// The Fuliza amount outstanding an SMS states, or null: the total on a
  /// loan message, or 0 after a full repayment. A Fuliza limit, the amount
  /// of one loan or a partial repayment is not the outstanding amount.
  static double? statedOutstanding(String? sms) {
    if (sms == null) return null;
    final text = sms.replaceAll(RegExp(r'\s+'), ' ');
    final m = _outstanding.firstMatch(text);
    if (m != null) return double.tryParse(m.group(1)!.replaceAll(',', ''));
    if (_fullyPaid.hasMatch(text)) return 0;
    return null;
  }

  /// The M-Pesa balance an SMS states, or null. Only the "balance is"
  /// wording counts: an amount paid, a Fuliza limit or a Fuliza total is
  /// not the remaining balance.
  static double? statedBalance(String? sms) {
    if (sms == null) return null;
    final m = _balance.firstMatch(sms);
    if (m == null) return null;
    return double.tryParse(m.group(1)!.replaceAll(',', ''));
  }
}
