import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../utils/formatters.dart';
import 'spending_report.dart';

/// A [SpendingReport] as a printable A4 PDF: header, summary, spending by
/// category and, optionally, every transaction (over as many pages as it
/// needs).
class SpendingReportPdf {
  SpendingReportPdf._();

  static const _green = PdfColor.fromInt(0xFF1B8A5A);
  static const _grey = PdfColor.fromInt(0xFF6B7280);
  static const _line = PdfColor.fromInt(0xFFE5E7EB);
  static const _headFill = PdfColor.fromInt(0xFFF3F4F6);

  static Future<Uint8List> build(
    SpendingReport report, {
    bool includeTransactions = true,
    String? userName,
    DateTime? generatedAt,
  }) {
    final doc = pw.Document(title: 'PennyWise spending report');
    final name = userName?.trim();
    final period =
        '${Formatters.shortDate(report.start)} - '
        '${Formatters.shortDate(report.lastDay)}';

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        footer: (context) => pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text(
            'Page ${context.pageNumber} of ${context.pagesCount}',
            style: const pw.TextStyle(fontSize: 8, color: _grey),
          ),
        ),
        build: (context) => [
          pw.Text(
            'PennyWise spending report',
            style: pw.TextStyle(
              fontSize: 20,
              fontWeight: pw.FontWeight.bold,
              color: _green,
            ),
          ),
          pw.SizedBox(height: 4),
          if (name != null && name.isNotEmpty) _text(name, size: 12),
          _text('$period  |  ${report.accountName}', size: 10),
          _text(
            'Generated ${Formatters.shortDate(generatedAt ?? DateTime.now())}',
            size: 9,
            color: _grey,
          ),
          pw.SizedBox(height: 16),
          _heading('Summary'),
          _table(
            const ['', 'Amount'],
            [
              ['Income', _money(report.income)],
              ['Spending', _money(report.spending)],
              ['Net', _money(report.net)],
              ['Fees and interest', _money(report.feesAndInterest)],
              ['Refunds', _money(report.refunds)],
              ['Loan principal repaid (not spending)',
                  _money(report.debtPrincipal)],
              ['Transfers between own accounts (not spending)',
                  _money(report.transfers)],
              if (report.netSaved case final saved?)
                ['Net saved (not spending)', _money(saved)],
            ],
            numeric: const {1},
          ),
          pw.SizedBox(height: 4),
          _text(
            'Spending = expenses + fees + interest - refunds.',
            size: 8,
            color: _grey,
          ),
          pw.SizedBox(height: 16),
          _heading('Spending by category'),
          if (report.categories.isEmpty)
            _text('No spending in this period.', size: 10, color: _grey)
          else
            _table(
              const ['Category', 'Amount', 'Share', 'Count'],
              [
                for (final c in report.categories)
                  [
                    c.name,
                    _money(c.amount),
                    '${(c.share * 100).toStringAsFixed(1)}%',
                    '${c.count}',
                  ],
              ],
              numeric: const {1, 2, 3},
            ),
          if (includeTransactions) ...[
            pw.SizedBox(height: 16),
            _heading('Transactions (${report.transactions.length})'),
            if (report.transactions.isEmpty)
              _text('No transactions in this period.', size: 10, color: _grey)
            else
              _table(
                const ['Date', 'Description', 'Type', 'Category', 'Account',
                    'Amount'],
                [
                  for (final t in report.transactions)
                    [
                      Formatters.shortDate(t.date),
                      t.description,
                      t.typeLabel,
                      t.category,
                      t.account,
                      _money(t.amount) +
                          (t.fee > 0 ? '\n+ fee ${_money(t.fee)}' : ''),
                    ],
                ],
                numeric: const {5},
                fontSize: 8,
                widths: const {
                  0: pw.FixedColumnWidth(58),
                  1: pw.FlexColumnWidth(3),
                  2: pw.FixedColumnWidth(52),
                  3: pw.FlexColumnWidth(2),
                  4: pw.FlexColumnWidth(2),
                  5: pw.FixedColumnWidth(72),
                },
              ),
            if (report.hideSavings)
              pw.Padding(
                padding: const pw.EdgeInsets.only(top: 4),
                child: _text(
                  'Savings moves are hidden (Hide savings is on).',
                  size: 8,
                  color: _grey,
                ),
              ),
          ],
        ],
      ),
    );
    return doc.save();
  }

  static pw.Widget _heading(String text) => pw.Padding(
    padding: const pw.EdgeInsets.only(bottom: 6),
    child: pw.Text(
      text,
      style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold),
    ),
  );

  static pw.Widget _text(String text, {double size = 10, PdfColor? color}) =>
      pw.Text(clean(text), style: pw.TextStyle(fontSize: size, color: color));

  static pw.Widget _table(
    List<String> headers,
    List<List<String>> rows, {
    Set<int> numeric = const {},
    double fontSize = 9,
    Map<int, pw.TableColumnWidth>? widths,
  }) => pw.TableHelper.fromTextArray(
    headers: headers,
    data: [
      for (final r in rows) [for (final c in r) clean(c)],
    ],
    headerStyle: pw.TextStyle(fontSize: fontSize, fontWeight: pw.FontWeight.bold),
    cellStyle: pw.TextStyle(fontSize: fontSize),
    headerDecoration: const pw.BoxDecoration(color: _headFill),
    border: const pw.TableBorder(
      horizontalInside: pw.BorderSide(color: _line, width: 0.5),
      bottom: pw.BorderSide(color: _line, width: 0.5),
    ),
    cellPadding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
    columnWidths: widths,
    cellAlignments: {
      for (var i = 0; i < headers.length; i++)
        i: numeric.contains(i) ? pw.Alignment.centerRight : pw.Alignment.centerLeft,
    },
    headerAlignments: {
      for (var i = 0; i < headers.length; i++)
        i: numeric.contains(i) ? pw.Alignment.centerRight : pw.Alignment.centerLeft,
    },
  );

  static String _money(double v) => Formatters.currency(v);

  /// The PDF's built-in font covers Latin-1 only: arrows and dashes become
  /// ASCII, anything else outside it (emoji, other scripts) becomes "?".
  static String clean(String text) {
    final s = text
        .replaceAll('→', '->')
        .replaceAll('–', '-')
        .replaceAll('—', '-')
        .replaceAll('•', '*')
        .replaceAll('‘', "'")
        .replaceAll('’', "'")
        .replaceAll('“', '"')
        .replaceAll('”', '"');
    final out = StringBuffer();
    for (final rune in s.runes) {
      out.write(rune <= 0xFF ? String.fromCharCode(rune) : '?');
    }
    return out.toString();
  }
}
