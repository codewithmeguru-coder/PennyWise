import 'package:flutter/material.dart';

import '../accounts/money_account.dart';
import '../data/transaction_store.dart';
import '../reports/fuliza_report.dart';
import '../sms/fuliza_import.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';
import '../widgets/charts/chart_style.dart';
import '../widgets/empty_state.dart';
import '../widgets/section_header.dart';

/// The period choices at the top of the report.
enum _Period { allTime, month, custom }

/// Settings › Fuliza fee report: fees, loans, repayments and what is owed,
/// from the transactions already saved. Read-only: it never writes.
class FulizaReportScreen extends StatefulWidget {
  const FulizaReportScreen({
    super.key,
    required this.store,
    this.accounts = const [],
  });

  final TransactionStore store;

  /// Used to tell each Fuliza account's SIM.
  final List<MoneyAccount> accounts;

  @override
  State<FulizaReportScreen> createState() => _FulizaReportScreenState();
}

class _FulizaReportScreenState extends State<FulizaReportScreen> {
  var _period = _Period.allTime;
  var _month = DateTime(DateTime.now().year, DateTime.now().month);
  DateTimeRange? _range;
  var _sim = FulizaSimFilter.all;

  FulizaFilter get _filter => switch (_period) {
    _Period.allTime => FulizaFilter(sim: _sim),
    _Period.month => FulizaFilter.month(_month, sim: _sim),
    _Period.custom => FulizaFilter(
      from: _range?.start,
      to: _range?.end,
      sim: _sim,
    ),
  };

  static const _clearTooltip = 'Clear date filter';

  /// Short enough to fit the chip beside its ✕: "1 Oct 2026",
  /// "1 – 9 Oct 2026", "28 Sep – 9 Oct 2026" or with both years.
  static String _rangeLabel(DateTimeRange r) {
    final start = Formatters.shortDate(r.start).split(' ');
    final end = Formatters.shortDate(r.end);
    if (DateUtils.isSameDay(r.start, r.end)) return end;
    if (r.start.year != r.end.year) return '${start.join(' ')} – $end';
    if (r.start.month != r.end.month) return '${start[0]} ${start[1]} – $end';
    return '${start[0]} – $end';
  }

  /// Back to the default period (all time). The SIM choice stays.
  void _clearDates() => setState(() {
    _period = _Period.allTime;
    _range = null;
    _month = DateTime(DateTime.now().year, DateTime.now().month);
  });

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: _range,
    );
    if (picked != null) {
      setState(() {
        _range = picked;
        _period = _Period.custom;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Fuliza fee report')),
      body: ListenableBuilder(
        listenable: widget.store,
        builder: (context, _) => _body(),
      ),
    );
  }

  Widget _body() {
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
    final report = FulizaReport.build(
      store.transactions,
      accounts: widget.accounts,
      filter: _filter,
    );
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _filters(),
        if (report.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 32),
            child: EmptyState(
              icon: Icons.credit_score_rounded,
              title: 'No Fuliza activity',
              message:
                  'No Fuliza loans or repayments are saved for this '
                  'period and SIM. Older Fuliza messages can be added from '
                  'Settings › Fuliza history.',
            ),
          )
        else ...[
          _Summary(report: report),
          _Warnings(report: report),
          const SectionHeader(title: 'Fees by month'),
          _card(
            Column(
              children: [
                _monthlyChart(report),
                if (report.monthlyFees.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _MonthlyFeeTable(report: report, sim: _sim),
                ],
              ],
            ),
          ),
          if (_sim == FulizaSimFilter.all) ...[
            const SectionHeader(title: 'Fees by SIM'),
            _card(_simChart(report)),
          ],
          const SectionHeader(title: 'Fee ledger'),
          for (final row in report.ledger) _LedgerTile(row: row),
        ],
        if (report.isEmpty && report.gaps.isNotEmpty) _Warnings(report: report),
      ],
    );
  }

  Widget _filters() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('All time'),
                selected: _period == _Period.allTime,
                onSelected: (_) => setState(() => _period = _Period.allTime),
              ),
              ChoiceChip(
                label: const Text('Month'),
                selected: _period == _Period.month,
                onSelected: (_) => setState(() => _period = _Period.month),
              ),
              InputChip(
                label: Text(
                  _period == _Period.custom && _range != null
                      ? _rangeLabel(_range!)
                      : 'Dates…',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                selected: _period == _Period.custom,
                showCheckmark: false,
                onSelected: (_) => _pickRange(),
                onDeleted: _period == _Period.custom ? _clearDates : null,
                deleteIcon: const Icon(Icons.close_rounded, size: 18),
                deleteButtonTooltipMessage: _clearTooltip,
              ),
            ],
          ),
          if (_period == _Period.month)
            Row(
              children: [
                IconButton(
                  tooltip: 'Previous month',
                  onPressed: () => setState(
                    () => _month = DateTime(_month.year, _month.month - 1),
                  ),
                  icon: const Icon(Icons.chevron_left_rounded),
                ),
                Expanded(
                  child: Text(
                    Formatters.monthYear(_month),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: 'Next month',
                  onPressed:
                      _month.year == DateTime.now().year &&
                          _month.month == DateTime.now().month
                      ? null
                      : () => setState(
                          () =>
                              _month = DateTime(_month.year, _month.month + 1),
                        ),
                  icon: const Icon(Icons.chevron_right_rounded),
                ),
                IconButton(
                  tooltip: _clearTooltip,
                  onPressed: _clearDates,
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          const SizedBox(height: 8),
          SegmentedButton<FulizaSimFilter>(
            showSelectedIcon: false,
            segments: [
              for (final s in FulizaSimFilter.values)
                ButtonSegment(value: s, label: Text(s.label)),
            ],
            selected: {_sim},
            onSelectionChanged: (s) => setState(() => _sim = s.first),
          ),
        ],
      ),
    );
  }

  Widget _card(Widget child) => Card(
    margin: const EdgeInsets.symmetric(horizontal: 16),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(8, 16, 16, 12),
      child: child,
    ),
  );

  Widget _monthlyChart(FulizaReport report) {
    final fees = report.monthlyFees;
    final months = fees.keys.toList()..sort();
    if (months.isEmpty) {
      return Text('No fees in this period.', style: ChartStyle.axisLabel(context));
    }
    final slots = _sim == FulizaSimFilter.all
        ? ({for (final m in fees.values) ...m.keys}.toList()
            ..sort((a, b) => (a ?? 9).compareTo(b ?? 9)))
        : [_sim.slot];
    return GroupedBarChart(
      labels: [for (final m in months) _shortMonth(m)],
      series: [
        for (final slot in slots)
          ChartSeries(_simName(slot), ChartStyle.sim(context, slot), [
            for (final m in months) fees[m]![slot] ?? 0,
          ]),
      ],
      semanticLabel: [
        for (final m in months)
          '${Formatters.monthYear(m)}: '
              '${Formatters.currency(fees[m]!.values.fold(0.0, (a, b) => a + b))}',
      ].join(', '),
    );
  }

  Widget _simChart(FulizaReport report) {
    final bySim = report.bySim;
    final slots = bySim.keys.toList()
      ..sort((a, b) => (a ?? 9).compareTo(b ?? 9));
    return GroupedBarChart(
      labels: const ['Fees'],
      series: [
        for (final slot in slots)
          ChartSeries(_simName(slot), ChartStyle.sim(context, slot), [
            bySim[slot]!.fees,
          ]),
      ],
      semanticLabel: [
        for (final slot in slots)
          '${_simName(slot)}: ${Formatters.currency(bySim[slot]!.fees)}',
      ].join(', '),
    );
  }

  static String _shortMonth(DateTime m) =>
      Formatters.monthYear(m).substring(0, 3);
}

String _simName(int? slot) => slot == null ? 'Unknown SIM' : 'SIM ${slot + 1}';

/// The numbers behind "Fees by month", newest month first: one column per
/// SIM and a total when more than one SIM had fees.
class _MonthlyFeeTable extends StatelessWidget {
  const _MonthlyFeeTable({required this.report, required this.sim});

  final FulizaReport report;
  final FulizaSimFilter sim;

  @override
  Widget build(BuildContext context) {
    final fees = report.monthlyFees;
    final months = fees.keys.toList()..sort((a, b) => b.compareTo(a));
    final slots = sim == FulizaSimFilter.all
        ? ({for (final m in fees.values) ...m.keys}.toList()
            ..sort((a, b) => (a ?? 9).compareTo(b ?? 9)))
        : [sim.slot];
    final showTotal = slots.length > 1;
    final head = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: context.colors.textSecondary,
    );
    Widget cell(String text, {TextStyle? style, bool left = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(
        text,
        textAlign: left ? TextAlign.left : TextAlign.right,
        style: style ?? const TextStyle(fontSize: 13),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Table(
        key: const Key('fuliza-month-table'),
        columnWidths: const {0: FlexColumnWidth(1.2)},
        border: TableBorder(
          horizontalInside: BorderSide(color: context.colors.divider),
        ),
        children: [
          TableRow(
            children: [
              cell('Month', style: head, left: true),
              for (final s in slots)
                cell(slots.length == 1 ? 'Fees' : _simName(s), style: head),
              if (showTotal) cell('Total', style: head),
            ],
          ),
          for (final m in months)
            TableRow(
              children: [
                cell(Formatters.monthYear(m), left: true),
                for (final s in slots)
                  cell(Formatters.currency(fees[m]![s] ?? 0)),
                if (showTotal)
                  cell(
                    Formatters.currency(
                      fees[m]!.values.fold(0.0, (a, b) => a + b),
                    ),
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.report});

  final FulizaReport report;

  @override
  Widget build(BuildContext context) {
    final t = report.totals;
    final owed = report.totalOutstanding;
    final allConfirmed = report.outstanding.values.every((o) => o.confirmed);
    final latest = report.outstanding.values.isEmpty
        ? null
        : report.outstanding.values
              .map((o) => o.asOf)
              .reduce((a, b) => a.isAfter(b) ? a : b);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 1.6,
        children: [
          _Stat(
            'Fees paid',
            Formatters.currency(t.fees),
            '${t.loans} ${t.loans == 1 ? 'loan' : 'loans'}'
                '${t.loans == 0 ? '' : ' · avg ${Formatters.currency(t.fees / t.loans)}'}',
            color: context.colors.expense,
          ),
          _Stat(
            'Borrowed',
            Formatters.currency(t.borrowed),
            'Not spending: moved into M-Pesa',
          ),
          _Stat(
            'Repaid',
            Formatters.currency(t.repaid),
            '${t.repayments} ${t.repayments == 1 ? 'repayment' : 'repayments'}',
          ),
          _Stat(
            'Owed now',
            owed == null ? 'Unknown' : Formatters.currency(owed),
            owed == null
                ? 'No Fuliza message states it'
                : '${allConfirmed ? 'Stated' : 'Estimated'} · '
                      '${Formatters.shortDate(latest!)}',
            color: context.colors.warning,
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.title, this.value, this.detail, {this.color});

  final String title, value, detail;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 12,
                color: context.colors.textSecondary,
              ),
            ),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: color ?? context.colors.textPrimary,
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              detail,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: context.colors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Data quality: unexplained owed amounts, unknown SIMs, duplicates, and
/// where the history starts. Nothing here changes any figure.
class _Warnings extends StatelessWidget {
  const _Warnings({required this.report});

  final FulizaReport report;

  @override
  Widget build(BuildContext context) {
    final lines = <String>[
      for (final slot in {for (final g in report.gaps) g.simSlot})
        _gapLine(slot),
      if (report.unknownSim > 0)
        '${report.unknownSim} Fuliza ${report.unknownSim == 1 ? 'record has' : 'records have'} '
            'no SIM. They count under All SIMs only.',
      if (report.duplicatesIgnored > 0)
        '${report.duplicatesIgnored} repeated Fuliza '
            '${report.duplicatesIgnored == 1 ? 'record was' : 'records were'} '
            'counted once.',
      'Fuliza history starts ${Formatters.shortDate(FulizaImporter.since)}. '
          'Earlier activity isn\'t included.',
    ];
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      color: context.colors.warning.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final l in lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 16,
                      color: context.colors.warning,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(l, style: const TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _gapLine(int slot) {
    final gaps = [
      for (final g in report.gaps)
        if (g.simSlot == slot) g,
    ];
    final total = gaps.fold<double>(0, (s, g) => s + g.amount);
    final when = [
      for (final g in gaps)
        '${Formatters.currency(g.amount)} by ${Formatters.shortDate(g.at)}',
    ].join(', ');
    return '${_simName(slot)}: Safaricom\'s messages show '
        '${Formatters.currency(total)} more owed than the saved loans and '
        'repayments explain ($when). No message for it is on this phone, so '
        'it isn\'t counted in borrowed or fees, and fees may be higher than '
        'shown. "Owed now" uses Safaricom\'s own figure.';
  }
}

class _LedgerTile extends StatelessWidget {
  const _LedgerTile({required this.row});

  final FulizaLedgerRow row;

  @override
  Widget build(BuildContext context) {
    final e = row.entry;
    final paid = row.paidFor;
    final status = e.simSlot == null
        ? 'SIM unknown'
        : row.repaid
        ? 'Repaid'
        : 'Outstanding';
    return ListTile(
      dense: true,
      leading: CircleAvatar(
        radius: 14,
        backgroundColor: ChartStyle.sim(context, e.simSlot).withValues(alpha: 0.15),
        child: Text(
          e.simSlot == null ? '?' : '${e.simSlot! + 1}',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: ChartStyle.sim(context, e.simSlot),
          ),
        ),
      ),
      title: Text(
        'Fee ${Formatters.currency(e.fee)} on '
        '${Formatters.currency(e.borrowed)}',
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        [
          '${Formatters.shortDate(e.date)} · ${_simName(e.simSlot)} · $status',
          if (paid != null)
            'For: ${paid.description} (${Formatters.currency(paid.amount)})'
          else if (e.transaction.reference case final code?)
            'Code $code',
        ].join('\n'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
