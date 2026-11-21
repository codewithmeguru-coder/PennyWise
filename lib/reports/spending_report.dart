import '../accounts/money_account.dart';
import '../models/ledger.dart';
import '../models/monthly_summary.dart';
import '../models/transaction_category.dart';
import '../models/transaction_model.dart';

/// One category's spending in a report.
class ReportCategoryRow {
  const ReportCategoryRow({
    required this.categoryId,
    required this.name,
    required this.amount,
    required this.share,
    required this.count,
  });

  final String categoryId;
  final String name;

  /// Net spending: expenses + fees + interest − refunds.
  final double amount;

  /// Fraction (0–1) of the report's category spending.
  final double share;

  /// Transactions that added to (or refunded) this category.
  final int count;
}

/// One transaction as a report lists it.
class ReportTransactionRow {
  const ReportTransactionRow({
    required this.date,
    required this.description,
    required this.category,
    required this.account,
    required this.amount,
    required this.fee,
    required this.typeLabel,
    required this.countsAsSpending,
  });

  final DateTime date;
  final String description;
  final String category;
  final String account;

  /// Positive when money came in, negative when it went out (seen from the
  /// account chosen, or from the account it was recorded against).
  final double amount;

  /// Charge on top of [amount]; 0 when none.
  final double fee;

  /// "Expense", "Income", "Transfer", "Savings", "Repayment" or "Refund".
  final String typeLabel;

  /// False for moves that aren't spending or income (transfers, savings,
  /// loan principal); only their fee, or a repayment's interest, counts.
  final bool countsAsSpending;
}

/// Income, spending and categories for a stretch of time, ready to show,
/// save as CSV or print as PDF.
///
/// Pure calculation over transactions already loaded. The money rules are
/// the [Ledger]'s (through [MonthlySummary.between]), so the totals always
/// match the dashboard:
/// - Spending = expenses + fees + Fuliza interest − refunds.
/// - Not spending: loan principal repaid, transfers between the user's own
///   accounts (SIM to SIM too), money into or out of savings. These are
///   still listed, so every transaction in the period can be seen.
class SpendingReport {
  SpendingReport._({
    required this.start,
    required this.end,
    required this.accountId,
    required this.accountName,
    required this.hideSavings,
    required this.summary,
    required this.categories,
    required this.transactions,
  });

  /// The report for [start] up to (not including) [end], local time.
  ///
  /// [accountId] keeps only transactions that leave or reach that one
  /// account (e.g. "mpesa-sim1"); null = all accounts. With [hideSavings]
  /// (the Hide savings setting) savings amounts and rows are left out.
  /// [categoryName] defaults to the app's category names, custom ones
  /// included.
  factory SpendingReport.build({
    required List<TransactionModel> transactions,
    required DateTime start,
    required DateTime end,
    String? accountId,
    List<MoneyAccount> accounts = const [],
    bool hideSavings = false,
    String Function(String categoryId)? categoryName,
  }) {
    final nameOf = categoryName ?? (id) => DefaultCategories.byId(id).name;
    final accountById = {for (final a in accounts) a.id: a};

    final kept = [
      for (final t in transactions)
        if (!t.date.isBefore(start) &&
            t.date.isBefore(end) &&
            (accountId == null ||
                t.accountId == accountId ||
                t.toAccountId == accountId))
          t,
    ]..sort((a, b) => a.date.compareTo(b.date));

    final summary = MonthlySummary.between(
      transactions: kept,
      start: start,
      end: end,
    );

    // How many transactions went into each category, by the same rules the
    // Ledger uses to put money there.
    final counts = <String, int>{};
    void count(String id) => counts.update(id, (c) => c + 1, ifAbsent: () => 1);
    for (final t in kept) {
      switch (t.type) {
        case TransactionType.expense || TransactionType.refund:
          count(t.categoryId);
        case TransactionType.debtRepayment when (t.interest ?? 0) > 0:
          count(t.categoryId);
        default:
          break;
      }
      if ((t.fee ?? 0) > 0) count(Ledger.feesCategory);
    }

    final categories = [
      for (final c in summary.byCategory)
        ReportCategoryRow(
          categoryId: c.categoryId,
          name: nameOf(c.categoryId),
          amount: c.amount,
          share: c.share,
          count: counts[c.categoryId] ?? 0,
        ),
    ];

    String accountLabel(TransactionModel t) {
      final from = accountById[t.accountId]?.name ??
          t.effectiveAccount?.label ??
          '';
      final to = accountById[t.toAccountId]?.name ?? t.toAccount?.label;
      final twoSided = t.type == TransactionType.transfer ||
          t.type == TransactionType.savingsContribution ||
          t.type == TransactionType.savingsWithdrawal ||
          t.type == TransactionType.debtRepayment;
      if (!twoSided || to == null || to == from) return from;
      // Money moves from the first to the second.
      return t.type == TransactionType.savingsWithdrawal
          ? '$to → $from'
          : from.isEmpty
          ? to
          : '$from → $to';
    }

    final rows = <ReportTransactionRow>[];
    for (final t in kept) {
      if (hideSavings && _isSavings(t)) continue;
      var moneyIn = t.type.isMoneyIn;
      // Seen from the chosen account, money sent to it came in.
      if (accountId != null &&
          t.accountId != accountId &&
          t.toAccountId == accountId) {
        moneyIn = !moneyIn;
      }
      rows.add(ReportTransactionRow(
        date: t.date,
        description: t.description,
        category: nameOf(t.categoryId),
        account: accountLabel(t),
        amount: moneyIn ? t.amount : -t.amount,
        fee: t.fee ?? 0,
        typeLabel: typeLabel(t.type),
        countsAsSpending: t.type == TransactionType.expense ||
            t.type == TransactionType.income ||
            t.type == TransactionType.refund,
      ));
    }

    return SpendingReport._(
      start: start,
      end: end,
      accountId: accountId,
      accountName: accountId == null
          ? 'All accounts'
          : accountById[accountId]?.name ?? accountId,
      hideSavings: hideSavings,
      summary: summary,
      categories: categories,
      transactions: rows,
    );
  }

  static bool _isSavings(TransactionModel t) =>
      t.type == TransactionType.savingsContribution ||
      t.type == TransactionType.savingsWithdrawal;

  /// Short type name for a report row.
  static String typeLabel(TransactionType type) => switch (type) {
    TransactionType.income => 'Income',
    TransactionType.expense => 'Expense',
    TransactionType.transfer => 'Transfer',
    TransactionType.savingsContribution ||
    TransactionType.savingsWithdrawal => 'Savings',
    TransactionType.refund => 'Refund',
    TransactionType.debtRepayment => 'Repayment',
  };

  /// First moment included.
  final DateTime start;

  /// First moment after the report (not included).
  final DateTime end;

  /// The account chosen, or null for all.
  final String? accountId;
  final String accountName;

  /// Savings amounts and rows are left out.
  final bool hideSavings;

  final MonthlySummary summary;

  /// Spending by category, largest first.
  final List<ReportCategoryRow> categories;

  /// Every transaction in the period (savings ones only when shown),
  /// oldest first.
  final List<ReportTransactionRow> transactions;

  Ledger get _ledger => summary.ledger;

  double get income => summary.income;

  /// Expenses + fees + interest − refunds.
  double get spending => summary.expenses;

  /// Income − spending.
  double get net => summary.net;

  /// Transaction charges plus loan interest (Fuliza).
  double get feesAndInterest =>
      Ledger.fromCents(_ledger.feeCents + _ledger.interestCents);

  double get refunds => _ledger.refunds;

  /// Loan principal repaid: not spending.
  double get debtPrincipal => _ledger.debtPrincipal;

  /// Money moved between the user's own accounts: not spending.
  double get transfers => Ledger.fromCents(_ledger.transferCents);

  /// Into savings minus out of savings; null while savings are hidden.
  double? get netSaved => hideSavings ? null : _ledger.netSaved;

  /// The last day included, for labels ("1 – 30 Nov 2026").
  DateTime get lastDay => DateTime(end.year, end.month, end.day - 1);

  bool get isEmpty => summary.transactionCount == 0;
}
