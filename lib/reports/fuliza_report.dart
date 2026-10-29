import '../accounts/money_account.dart';
import '../models/transaction_model.dart';

/// Which SIM's Fuliza a report covers.
enum FulizaSimFilter {
  all('All SIMs'),
  sim1('SIM 1'),
  sim2('SIM 2');

  const FulizaSimFilter(this.label);
  final String label;

  /// The slot this filter keeps (0 = SIM 1), or null for all.
  int? get slot => switch (this) {
    FulizaSimFilter.all => null,
    FulizaSimFilter.sim1 => 0,
    FulizaSimFilter.sim2 => 1,
  };

  bool includes(int? slot) => this == FulizaSimFilter.all || slot == this.slot;
}

/// The period and SIM a report covers. [from] and [to] are whole days,
/// both included; null means no limit on that side.
class FulizaFilter {
  const FulizaFilter({this.from, this.to, this.sim = FulizaSimFilter.all});

  /// Exactly one calendar month.
  factory FulizaFilter.month(
    DateTime month, {
    FulizaSimFilter sim = FulizaSimFilter.all,
  }) => FulizaFilter(
    from: DateTime(month.year, month.month),
    to: DateTime(month.year, month.month + 1, 0),
    sim: sim,
  );

  final DateTime? from;
  final DateTime? to;
  final FulizaSimFilter sim;

  /// The first moment after [to], or null.
  DateTime? get _end =>
      to == null ? null : DateTime(to!.year, to!.month, to!.day + 1);

  bool inRange(DateTime date) =>
      (from == null ||
          !date.isBefore(DateTime(from!.year, from!.month, from!.day))) &&
      (_end == null || date.isBefore(_end!));

  /// Up to and including [to] (no lower limit): what has happened by then.
  bool upToEnd(DateTime date) => _end == null || date.isBefore(_end!);

  FulizaFilter copyWith({DateTime? from, DateTime? to, FulizaSimFilter? sim}) =>
      FulizaFilter(
        from: from ?? this.from,
        to: to ?? this.to,
        sim: sim ?? this.sim,
      );
}

/// One Fuliza movement, read from a saved transaction.
class FulizaEntry {
  const FulizaEntry({
    required this.transaction,
    required this.isDraw,
    required this.simSlot,
    this.statedOutstanding,
    this.fullyRepaid = false,
  });

  final TransactionModel transaction;

  /// A loan (money borrowed); otherwise a repayment.
  final bool isDraw;

  /// 0 = SIM 1, 1 = SIM 2, null when it isn't known.
  final int? simSlot;

  /// "Total Fuliza M-PESA outstanding amount is Ksh …" in a loan message:
  /// what Safaricom said was owed right after it.
  final double? statedOutstanding;

  /// A repayment message saying it "fully" paid the debt.
  final bool fullyRepaid;

  DateTime get date => transaction.date;
  double get borrowed => isDraw ? transaction.amount : 0;

  /// The access fee on a loan. Repayments carry none: the fee is counted
  /// once, on the loan it was charged for.
  double get fee => isDraw ? (transaction.fee ?? 0) : 0;
  double get repaid => isDraw ? 0 : transaction.amount;
}

/// Owed amount that no message explains: what Safaricom stated differs
/// from the previous statement plus the loans and repayments in between.
/// Never added to any total; only reported.
class FulizaGap {
  const FulizaGap({
    required this.simSlot,
    required this.after,
    required this.at,
    required this.amount,
  });

  final int simSlot;

  /// The last message that agreed, and the one that didn't.
  final DateTime after, at;

  /// Positive: more was owed than the messages explain.
  final double amount;
}

/// What is owed on one SIM's Fuliza at the end of the report period.
class FulizaOutstanding {
  const FulizaOutstanding({
    required this.simSlot,
    required this.amount,
    required this.asOf,
    required this.confirmed,
  });

  final int simSlot;
  final double amount;

  /// Date of the message it comes from.
  final DateTime asOf;

  /// Stated in that message (a loan's "outstanding amount", or a "fully"
  /// paid repayment, i.e. zero). Otherwise worked out from the messages
  /// since the last statement.
  final bool confirmed;
}

/// One row of the fee ledger: a loan and its fee.
class FulizaLedgerRow {
  const FulizaLedgerRow(this.entry, {this.paidFor, required this.repaid});

  final FulizaEntry entry;

  /// The payment the loan completed (the M-Pesa transaction with the same
  /// code), when it is saved.
  final TransactionModel? paidFor;

  /// A later repayment on the same SIM cleared the whole debt.
  final bool repaid;
}

/// Totals for one SIM (or for unknown SIMs, under null).
class FulizaTotals {
  int loans = 0, repayments = 0;
  double borrowed = 0, fees = 0, repaid = 0;

  void add(FulizaEntry e) {
    if (e.isDraw) {
      loans++;
      borrowed += e.borrowed;
      fees += e.fee;
    } else {
      repayments++;
      repaid += e.repaid;
    }
  }
}

/// Fuliza fees, loans and repayments, from transactions already saved.
///
/// Pure calculation: nothing is read from or written to anywhere.
/// - A loan is a transfer out of a Fuliza (loan) account; a repayment is a
///   debt repayment into one. Records saved before accounts existed are
///   recognised by their message wording.
/// - Each record counts once: by id, and by its M-Pesa code within loans
///   or repayments. The payment a loan completed shares that code but is
///   not a Fuliza record, so its own M-Pesa charge is never a Fuliza fee.
/// - Fees are loans' access fees only.
/// - Outstanding is never invented: it is the latest amount Safaricom
///   stated, and only loans and repayments after it are applied.
class FulizaReport {
  FulizaReport._(
    this.filter,
    this.entries,
    this._all,
    this.duplicatesIgnored,
    this.gaps,
    this.outstanding,
    this._payments,
  );

  factory FulizaReport.build(
    List<TransactionModel> transactions, {
    List<MoneyAccount> accounts = const [],
    FulizaFilter filter = const FulizaFilter(),
  }) {
    final loanSims = {
      for (final a in accounts)
        if (a.kind == AccountKind.loan) a.id: a.simSlot,
    };
    final simOf = {for (final a in accounts) a.id: a.simSlot};

    final seenIds = <String>{};
    final seenCodes = <String>{};
    var duplicates = 0;
    final all = <FulizaEntry>[];
    final payments = <String, TransactionModel>{};
    for (final t in transactions) {
      final entry = _read(t, loanSims, simOf);
      if (entry == null) {
        if (t.reference case final code?) payments.putIfAbsent(code, () => t);
        continue;
      }
      final code = t.reference == null
          ? null
          : '${entry.isDraw ? 'loan' : 'repay'}:${t.reference}';
      if ((t.id.isNotEmpty && !seenIds.add(t.id)) ||
          (code != null && !seenCodes.add(code))) {
        duplicates++;
        continue;
      }
      all.add(entry);
    }
    _chainOrder(all);

    final gaps = <FulizaGap>[];
    final outstanding = <int, FulizaOutstanding>{};
    for (final slot in {for (final e in all) e.simSlot}.whereType<int>()) {
      if (!filter.sim.includes(slot)) continue;
      _walk(
        [
          for (final e in all)
            if (e.simSlot == slot && filter.upToEnd(e.date)) e,
        ],
        slot,
        gaps,
        outstanding,
      );
    }

    final shown = [
      for (final e in all)
        if (filter.sim.includes(e.simSlot) && filter.inRange(e.date)) e,
    ];
    return FulizaReport._(
      filter,
      shown,
      all,
      duplicates,
      gaps,
      outstanding,
      payments,
    );
  }

  final FulizaFilter filter;

  /// Loans and repayments in the period and SIM chosen, oldest first.
  final List<FulizaEntry> entries;
  final List<FulizaEntry> _all;

  /// Records skipped because the same loan or repayment was already counted.
  final int duplicatesIgnored;

  /// Unexplained owed amounts on the SIMs chosen, up to the period's end.
  final List<FulizaGap> gaps;

  /// Per SIM chosen, as of the period's end. Missing when nothing is known.
  final Map<int, FulizaOutstanding> outstanding;
  final Map<String, TransactionModel> _payments;

  bool get isEmpty => entries.isEmpty;

  FulizaTotals get totals {
    final t = FulizaTotals();
    for (final e in entries) {
      t.add(e);
    }
    return t;
  }

  /// Per SIM slot; null collects records whose SIM isn't known.
  Map<int?, FulizaTotals> get bySim {
    final out = <int?, FulizaTotals>{};
    for (final e in entries) {
      (out[e.simSlot] ??= FulizaTotals()).add(e);
    }
    return out;
  }

  /// Fees per calendar month (first day of the month), per SIM slot.
  Map<DateTime, Map<int?, double>> get monthlyFees {
    final out = <DateTime, Map<int?, double>>{};
    for (final e in entries) {
      if (!e.isDraw) continue;
      final month = DateTime(e.date.year, e.date.month);
      final bySim = out[month] ??= {};
      bySim[e.simSlot] = (bySim[e.simSlot] ?? 0) + e.fee;
    }
    return out;
  }

  /// Loans whose SIM isn't known: counted under All SIMs only.
  int get unknownSim => entries.where((e) => e.simSlot == null).length;

  double? get totalOutstanding => outstanding.isEmpty
      ? null
      : outstanding.values.fold<double>(0, (s, o) => s + o.amount);

  double get totalGap => gaps.fold<double>(0, (s, g) => s + g.amount);

  /// Loans in the period, newest first.
  List<FulizaLedgerRow> get ledger => [
    for (final e in entries.reversed)
      if (e.isDraw)
        FulizaLedgerRow(
          e,
          paidFor: e.transaction.reference == null
              ? null
              : _payments[e.transaction.reference],
          repaid: _all.any(
            (r) =>
                !r.isDraw &&
                r.fullyRepaid &&
                r.simSlot == e.simSlot &&
                e.simSlot != null &&
                r.date.isAfter(e.date),
          ),
        ),
  ];

  static final _outstanding = RegExp(
    r'outstanding\s+amount\s+is\s+ksh\.?\s*([\d,]+(?:\.\d+)?)',
    caseSensitive: false,
  );
  static final _drawText = RegExp(
    r'fuliza\s+m-?pesa\s+amount\s+is',
    caseSensitive: false,
  );
  static final _repayText = RegExp(
    r'(fully|partially)\s+pay\s+your\s+outstanding\s+fuliza',
    caseSensitive: false,
  );

  static FulizaEntry? _read(
    TransactionModel t,
    Map<String, int?> loanSims,
    Map<String, int?> simOf,
  ) {
    final text = t.smsText ?? '';
    final bool isDraw;
    if (t.type == TransactionType.transfer &&
        (loanSims.containsKey(t.accountId) || _drawText.hasMatch(text))) {
      isDraw = true;
    } else if (t.type == TransactionType.debtRepayment &&
        (loanSims.containsKey(t.toAccountId) || _repayText.hasMatch(text))) {
      isDraw = false;
    } else {
      return null;
    }
    final loanId = isDraw ? t.accountId : t.toAccountId;
    final slot =
        t.simSlot ??
        loanSims[loanId] ??
        simOf[isDraw ? t.toAccountId : t.accountId];
    final stated = _outstanding.firstMatch(text)?.group(1);
    return FulizaEntry(
      transaction: t,
      isDraw: isDraw,
      simSlot: slot,
      statedOutstanding: isDraw && stated != null
          ? double.parse(stated.replaceAll(',', ''))
          : null,
      fullyRepaid:
          !isDraw &&
          _repayText.firstMatch(text)?.group(1)?.toLowerCase() == 'fully',
    );
  }

  /// By date, except that loans in a row within the same minute go by what
  /// they say is owed: the debt only grows with each loan, and messages
  /// from the same minute can arrive out of order.
  static void _chainOrder(List<FulizaEntry> list) {
    list.sort((a, b) => a.date.compareTo(b.date));
    DateTime minute(DateTime d) =>
        DateTime(d.year, d.month, d.day, d.hour, d.minute);
    var start = 0;
    while (start < list.length) {
      var end = start + 1;
      while (end < list.length &&
          list[start].isDraw &&
          list[end].isDraw &&
          list[start].statedOutstanding != null &&
          list[end].statedOutstanding != null &&
          minute(list[end].date) == minute(list[start].date)) {
        end++;
      }
      if (end - start > 1) {
        final run = list.sublist(
          start,
          end,
        )..sort((a, b) => a.statedOutstanding!.compareTo(b.statedOutstanding!));
        list.setRange(start, end, run);
      }
      start = end;
    }
  }

  /// Follows what is owed on one SIM through its messages, oldest first.
  static void _walk(
    List<FulizaEntry> chain,
    int slot,
    List<FulizaGap> gaps,
    Map<int, FulizaOutstanding> outstanding,
  ) {
    double? owed; // null until a message says how much is owed
    var confirmed = false;
    DateTime? lastAgreed;
    void check(double expected, double actual, DateTime at) {
      final diff = actual - expected;
      if (diff.abs() >= 0.01 && lastAgreed != null) {
        gaps.add(
          FulizaGap(
            simSlot: slot,
            after: lastAgreed,
            at: at,
            amount: (diff * 100).roundToDouble() / 100,
          ),
        );
      }
    }

    for (final e in chain) {
      if (e.isDraw) {
        final expected = owed == null ? null : owed + e.borrowed + e.fee;
        if (e.statedOutstanding case final stated?) {
          if (expected != null) check(expected, stated, e.date);
          owed = stated;
          confirmed = true;
          lastAgreed = e.date;
        } else if (expected != null) {
          owed = expected;
          confirmed = false;
        }
      } else if (e.fullyRepaid) {
        // A full repayment states what was owed: exactly its amount.
        if (owed != null) check(owed, e.repaid, e.date);
        owed = 0;
        confirmed = true;
        lastAgreed = e.date;
      } else if (owed != null) {
        owed = owed - e.repaid;
        confirmed = false;
      }
      if (owed != null) {
        outstanding[slot] = FulizaOutstanding(
          simSlot: slot,
          amount: owed,
          asOf: e.date,
          confirmed: confirmed,
        );
      }
    }
  }
}
