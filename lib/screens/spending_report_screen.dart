import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../accounts/money_account.dart';
import '../data/transaction_store.dart';
import '../privacy/savings_privacy.dart';
import '../reports/spending_report.dart';
import '../reports/spending_report_csv.dart';
import '../reports/spending_report_pdf.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';
import '../widgets/empty_state.dart';
import '../widgets/section_header.dart';

enum _Period { thisMonth, lastMonth, custom }

enum ReportFormat { pdf, csv }

/// Writes report bytes somewhere and hands them to the share sheet. Swapped
/// out in tests, where there is no share sheet.
typedef ReportSharer =
    Future<void> Function(String fileName, List<int> bytes, String mimeType);

/// Reports & Budgets › Download report: income, spending and categories for
/// a period and account, saved as a PDF or CSV and opened in the Android
/// share sheet (to save to Files, email, WhatsApp...). Read-only: it never
/// writes to the user's data.
class SpendingReportScreen extends StatefulWidget {
  const SpendingReportScreen({
    super.key,
    required this.store,
    this.accounts = const [],
    this.userName,
    this.share,
  });

  final TransactionStore store;

  /// The user's accounts, for the account filter and account names.
  final List<MoneyAccount> accounts;

  /// Printed on the PDF when known.
  final String? userName;

  /// Defaults to a temp file plus the share sheet.
  final ReportSharer? share;

  @override
  State<SpendingReportScreen> createState() => _SpendingReportScreenState();
}

class _SpendingReportScreenState extends State<SpendingReportScreen> {
  var _period = _Period.thisMonth;
  DateTimeRange? _range;
  String? _accountId;
  var _format = ReportFormat.pdf;
  var _includeTransactions = true;
  var _busy = false;

  /// [start, end) for the period chosen, local time.
  (DateTime, DateTime) get _bounds {
    final now = DateTime.now();
    return switch (_period) {
      _Period.thisMonth => (
        DateTime(now.year, now.month),
        DateTime(now.year, now.month + 1),
      ),
      _Period.lastMonth => (
        DateTime(now.year, now.month - 1),
        DateTime(now.year, now.month),
      ),
      _Period.custom => (
        DateTime(_range!.start.year, _range!.start.month, _range!.start.day),
        DateTime(_range!.end.year, _range!.end.month, _range!.end.day + 1),
      ),
    };
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: _range,
    );
    if (picked != null && mounted) {
      setState(() {
        _range = picked;
        _period = _Period.custom;
      });
    }
  }

  SpendingReport _build(bool hideSavings) {
    final (start, end) = _bounds;
    return SpendingReport.build(
      transactions: widget.store.transactions,
      start: start,
      end: end,
      accountId: _accountId,
      accounts: widget.accounts,
      hideSavings: hideSavings,
    );
  }

  Future<void> _export(SpendingReport report) async {
    setState(() => _busy = true);
    final stamp = '${_isoDay(report.start)}_to_${_isoDay(report.lastDay)}';
    try {
      final List<int> bytes;
      final String name, mime;
      if (_format == ReportFormat.pdf) {
        bytes = await SpendingReportPdf.build(
          report,
          includeTransactions: _includeTransactions,
          userName: widget.userName,
        );
        name = 'pennywise_report_$stamp.pdf';
        mime = 'application/pdf';
      } else {
        // A byte-order mark so Excel reads the file as UTF-8.
        bytes = utf8.encode(
          '﻿${SpendingReportCsv.build(report, includeTransactions: _includeTransactions)}',
        );
        name = 'pennywise_report_$stamp.csv';
        mime = 'text/csv';
      }
      await (widget.share ?? _shareFile)(name, bytes, mime);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Couldn\'t create the report. $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static Future<void> _shareFile(
    String name,
    List<int> bytes,
    String mime,
  ) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(bytes, flush: true);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: mime)],
        subject: 'PennyWise spending report',
        title: 'Save or share report',
      ),
    );
  }

  static String _isoDay(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Download report')),
      body: ListenableBuilder(
        listenable: widget.store,
        builder: (context, _) => _body(context),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final store = widget.store;
    if (store.error != null) {
      return EmptyState(
        icon: Icons.cloud_off_rounded,
        title: 'Couldn\'t load transactions',
        message: store.error!,
        actionLabel: 'Retry',
        onAction: store.retry,
      );
    }
    if (store.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final report = _build(SavingsPrivacy.hidden(context));
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              _options(context),
              if (report.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: EmptyState(
                    icon: Icons.description_outlined,
                    title: 'Nothing to report',
                    message:
                        'No transactions are saved for this period and '
                        'account. Try another period or All accounts.',
                  ),
                )
              else ...[
                _Totals(report: report),
                const SectionHeader(title: 'Spending by category'),
                if (report.categories.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      'No spending in this period.',
                      style: TextStyle(color: context.colors.textSecondary),
                    ),
                  )
                else
                  for (final c in report.categories)
                    ListTile(
                      dense: true,
                      title: Text(c.name),
                      subtitle: Text(
                        '${c.count} ${c.count == 1 ? 'transaction' : 'transactions'}'
                        ' · ${(c.share * 100).toStringAsFixed(1)}%',
                      ),
                      trailing: Text(
                        Formatters.currency(c.amount),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(
                    '${report.transactions.length} transactions in the file'
                    '${report.hideSavings ? ' (savings moves hidden)' : ''}. '
                    'Transfers, savings and loan principal are listed but '
                    'not counted as spending.',
                    style: TextStyle(
                      fontSize: 12,
                      color: context.colors.textSecondary,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: report.isEmpty || _busy
                    ? null
                    : () => _export(report),
                icon: _busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.ios_share_rounded),
                label: Text(
                  'Share / Save ${_format == ReportFormat.pdf ? 'PDF' : 'CSV'}',
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _options(BuildContext context) {
    final accounts = [
      for (final a in widget.accounts)
        if (a.active || a.id == _accountId) a,
    ];
    final (start, end) = _bounds;
    final last = DateTime(end.year, end.month, end.day - 1);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              ChoiceChip(
                label: const Text('This month'),
                selected: _period == _Period.thisMonth,
                onSelected: (_) =>
                    setState(() => _period = _Period.thisMonth),
              ),
              ChoiceChip(
                label: const Text('Last month'),
                selected: _period == _Period.lastMonth,
                onSelected: (_) =>
                    setState(() => _period = _Period.lastMonth),
              ),
              ChoiceChip(
                label: const Text('Custom…'),
                selected: _period == _Period.custom,
                onSelected: (_) => _pickRange(),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              '${Formatters.shortDate(start)} – ${Formatters.shortDate(last)}',
              style: TextStyle(color: context.colors.textSecondary),
            ),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String?>(
            initialValue: _accountId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Account'),
            items: [
              const DropdownMenuItem(value: null, child: Text('All accounts')),
              for (final a in accounts)
                DropdownMenuItem(
                  value: a.id,
                  child: Text(a.name, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (id) => setState(() => _accountId = id),
          ),
          const SizedBox(height: 12),
          SegmentedButton<ReportFormat>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: ReportFormat.pdf,
                label: Text('PDF'),
                icon: Icon(Icons.picture_as_pdf_outlined),
              ),
              ButtonSegment(
                value: ReportFormat.csv,
                label: Text('CSV'),
                icon: Icon(Icons.table_chart_outlined),
              ),
            ],
            selected: {_format},
            onSelectionChanged: (s) => setState(() => _format = s.first),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Include transactions'),
            subtitle: const Text('List every transaction in the file'),
            value: _includeTransactions,
            onChanged: (v) => setState(() => _includeTransactions = v),
          ),
        ],
      ),
    );
  }
}

class _Totals extends StatelessWidget {
  const _Totals({required this.report});

  final SpendingReport report;

  @override
  Widget build(BuildContext context) {
    final saved = report.netSaved;
    Widget row(String label, double value, {Color? color, bool bold = false}) =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Expanded(child: Text(label)),
              Text(
                Formatters.currency(value),
                style: TextStyle(
                  color: color,
                  fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        );
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            row('Income', report.income, color: context.colors.income),
            row('Spending', report.spending, color: context.colors.expense),
            const Divider(),
            row('Net', report.net, bold: true),
            row('Fees and interest', report.feesAndInterest),
            if (report.debtPrincipal > 0)
              row('Loan repaid (not spending)', report.debtPrincipal),
            if (report.transfers > 0)
              row('Transfers (not spending)', report.transfers),
            if (saved != null && saved != 0)
              row('Net saved (not spending)', saved,
                  color: context.colors.savings),
          ],
        ),
      ),
    );
  }
}
