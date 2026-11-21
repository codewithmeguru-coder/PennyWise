import '../utils/formatters.dart';
import 'spending_report.dart';

/// A [SpendingReport] as CSV text, for spreadsheets.
///
/// Three sections, each with its own header row and a blank line between
/// them: Summary, Spending by category, and (optionally) Transactions.
/// Amounts are KSh with 2 decimals and no thousands separators, so they
/// stay numbers in a spreadsheet.
class SpendingReportCsv {
  SpendingReportCsv._();

  static String build(
    SpendingReport report, {
    bool includeTransactions = true,
    DateTime? generatedAt,
  }) {
    final rows = <List<String>>[
      ['PennyWise spending report'],
      ['Period', '${_date(report.start)} to ${_date(report.lastDay)}'],
      ['Account', report.accountName],
      ['Generated', _date(generatedAt ?? DateTime.now())],
      [],
      ['Summary', 'Amount (${Formatters.currencySymbol})'],
      ['Income', amount(report.income)],
      ['Spending', amount(report.spending)],
      ['Net', amount(report.net)],
      ['Fees and interest', amount(report.feesAndInterest)],
      ['Refunds', amount(report.refunds)],
      ['Loan principal repaid (not spending)', amount(report.debtPrincipal)],
      ['Transfers between own accounts (not spending)',
          amount(report.transfers)],
      if (report.netSaved case final saved?)
        ['Net saved (not spending)', amount(saved)],
      [],
      [
        'Category',
        'Amount (${Formatters.currencySymbol})',
        'Share (%)',
        'Transactions',
      ],
      for (final c in report.categories)
        [
          c.name,
          amount(c.amount),
          (c.share * 100).toStringAsFixed(1),
          '${c.count}',
        ],
      if (includeTransactions) ...[
        [],
        [
          'Date',
          'Description',
          'Type',
          'Category',
          'Account',
          'Amount (${Formatters.currencySymbol})',
          'Fee (${Formatters.currencySymbol})',
        ],
        for (final t in report.transactions)
          [
            _date(t.date),
            t.description,
            t.typeLabel,
            t.category,
            t.account,
            amount(t.amount),
            amount(t.fee),
          ],
      ],
    ];
    // CRLF line endings, as RFC 4180 asks; Excel and Sheets read either.
    return '${rows.map((r) => r.map(field).join(',')).join('\r\n')}\r\n';
  }

  /// 1234.5 -> "1234.50"; -3 -> "-3.00".
  static String amount(double value) {
    final cents = (value * 100).round();
    final sign = cents < 0 ? '-' : '';
    final abs = cents.abs();
    return '$sign${abs ~/ 100}.${(abs % 100).toString().padLeft(2, '0')}';
  }

  /// [value] quoted when it holds a comma, quote or line break, with any
  /// quotes doubled. A leading =, +, - or @ is prefixed with ' so a
  /// spreadsheet never runs a description as a formula.
  static String field(String value) {
    var v = value;
    if (v.isNotEmpty &&
        '=+-@'.contains(v[0]) &&
        double.tryParse(v) == null) {
      v = "'$v";
    }
    if (v.contains(RegExp(r'[",\r\n]'))) {
      return '"${v.replaceAll('"', '""')}"';
    }
    return v;
  }

  /// ISO date, e.g. "2026-11-19": sorts and imports cleanly.
  static String _date(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}
