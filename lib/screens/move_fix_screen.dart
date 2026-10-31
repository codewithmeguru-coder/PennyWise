import 'package:flutter/material.dart';

import '../accounts/money_account.dart';
import '../maintenance/internal_transfer_fix.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';

/// Settings › Fix moves between your accounts: shows which records are really
/// money moved between the user's own accounts (by both SIMs' messages, or
/// an agent cash withdrawal), what that does to each month and to the
/// cards, and changes them only after a confirmation, with a backup first.
/// Undo puts back exactly what it changed.
class MoveFixScreen extends StatefulWidget {
  const MoveFixScreen({super.key, required this.fix});

  final MoveFix fix;

  @override
  State<MoveFixScreen> createState() => _MoveFixScreenState();
}

class _MoveFixScreenState extends State<MoveFixScreen> {
  MovePreview? _preview;
  List<String> _changed = const [];
  List<String> _log = const [];
  String? _error;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _preview = null;
    });
    try {
      final preview = await widget.fix.preview();
      final changed = await widget.fix.changedIds();
      // The saved log, so a run's record survives the app closing.
      final log = await widget.fix.lastLog();
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _changed = changed;
        _log = log.length > 60 ? log.sublist(log.length - 60) : log;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Couldn\'t read your transactions. Try again.');
    }
  }

  Future<bool> _confirm(String title, String text, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(child: Text(text)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _run(
    Future<MoveRunResult> Function() job,
    String Function(MoveRunResult) describe,
  ) async {
    if (_working) return;
    setState(() => _working = true);
    MoveRunResult r;
    try {
      r = await job();
    } catch (_) {
      // E.g. this phone's storage failed: the run stopped before (or at)
      // that point, so say so plainly and stop the spinner.
      r = const MoveRunResult(
        error:
            'Something on this phone failed. Nothing more was changed; '
            'check the log below before trying again.',
      );
    }
    if (!mounted) return;
    setState(() => _working = false);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(describe(r))));
    await _load();
  }

  static String _signed(double v) =>
      '${v > 0 ? '+' : ''}${Formatters.currency(v)}';

  static String _amounts(Map<MoneyAccount, double> m) =>
      [for (final e in m.entries) '${e.key.name} ${_signed(e.value)}']
          .join('\n');

  /// "Sep 2026: spending KSh 138,367.26 → KSh 85,144.26 (−53,223.00)".
  static List<String> _monthLines(MovePreview p) => [
    for (final m in p.months)
      '${Formatters.monthYear(m.month)}: spending '
          '${Formatters.currency(m.before.expenses)} → '
          '${Formatters.currency(m.after.expenses)} '
          '(${_signed(m.after.expenses - m.before.expenses)}); income '
          '${Formatters.currency(m.before.income)} → '
          '${Formatters.currency(m.after.income)} '
          '(${_signed(m.after.income - m.before.income)})',
  ];

  static String _cardsText(MovePreview p) =>
      p.cards.isEmpty ? 'No change.' : _amounts(p.cards);

  Future<void> _apply() async {
    final p = _preview!;
    if (!await _confirm(
      'Fix ${p.changes.length} records?',
      'They become transfers between your own accounts, so they no longer '
          'count as spending or income. Amounts, dates, codes and notes stay '
          'the same.\n\n'
          '${_monthLines(p).join('\n')}\n\n'
          'Fees from the messages added as spending: '
          '${Formatters.currency(p.feesAdded)}\n\n'
          'Change to your account card balances:\n${_cardsText(p)}\n\n'
          'A backup is saved on this phone first, and you can undo this.',
      'Back up and fix',
    )) {
      return;
    }
    await _run(
      () => widget.fix.apply(p),
      (r) => r.error == null
          ? 'Fixed ${r.done}${r.skipped > 0 ? ' (${r.skipped} left alone)' : ''}.'
          : 'Stopped after ${r.done}: ${r.error}',
    );
  }

  Future<void> _undo() async {
    if (!await _confirm(
      'Undo the fix?',
      'The ${_changed.length} records it changed go back to exactly what '
          'they were. Any you edited since are left alone.',
      'Undo',
    )) {
      return;
    }
    await _run(
      widget.fix.undo,
      (r) => r.error == null
          ? 'Undone ${r.done}${r.skipped > 0 ? ' (${r.skipped} edited since, left as they are)' : ''}.'
          : 'Stopped after ${r.done}: ${r.error}',
    );
  }

  Widget _row(MoveChange c) => Text(
    '${Formatters.shortDate(c.record.date)} · '
    '${Formatters.currency(c.record.amount)} · ${c.record.type} → '
    '${switch (c.kind) {
      MoveKind.cashWithdrawal => 'SIM ${c.fromSim + 1} M-Pesa → Cash',
      MoveKind.intoBank => 'SIM ${c.fromSim + 1} M-Pesa → Equity',
      MoveKind.betweenSims => 'SIM ${c.fromSim + 1} → SIM ${c.toSim! + 1} M-Pesa',
    }}'
    '${c.addFee != null ? ' · fee ${Formatters.currency(c.addFee!)}' : ''}',
    style: TextStyle(fontSize: 12, color: context.colors.textSecondary),
  );

  @override
  Widget build(BuildContext context) {
    final p = _preview;
    const label = TextStyle(fontWeight: FontWeight.w600);
    return Scaffold(
      appBar: AppBar(title: const Text('Fix moves between your accounts')),
      body: _error != null
          ? Center(child: Text(_error!))
          : p == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'Money you moved between your own SIMs, or withdrew '
                  'as cash, saved as spending or income. Found by your '
                  'phone\'s own messages: sent on one SIM and received '
                  'on the other. Nothing has been changed yet.',
                  style: TextStyle(color: context.colors.textSecondary),
                ),
                const SizedBox(height: 12),
                Text(
                  'Ready: ${p.changes.length} '
                  '(${p.count(MoveKind.betweenSims)} between your SIMs, '
                  '${p.count(MoveKind.intoBank)} into Equity, '
                  '${p.count(MoveKind.cashWithdrawal)} cash withdrawals)',
                  key: const Key('move-ready'),
                  style: label,
                ),
                for (final c in p.changes) _row(c),
                if (p.blocked.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Waiting: ${p.blocked.length} cash withdrawals',
                    key: const Key('move-blocked'),
                    style: label,
                  ),
                  Text(
                    'Set your Cash starting balance first (Accounts › '
                    'Cash), so cash you already spent doesn\'t show as '
                    'held today.',
                    style: TextStyle(color: context.colors.warning),
                  ),
                  for (final c in p.blocked) _row(c),
                ],
                for (final e in p.skipped.entries)
                  Text(
                    'Left alone, ${e.key.toLowerCase()}: ${e.value}',
                    style: TextStyle(color: context.colors.textSecondary),
                  ),
                if (p.changes.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text('Monthly totals', style: label),
                  for (final line in _monthLines(p)) Text(line),
                  Text(
                    'Fees from the messages added as spending: '
                    '${Formatters.currency(p.feesAdded)}',
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Past totals per account (not a balance change):',
                    style: label,
                  ),
                  Text(
                    p.history.isEmpty ? 'None.' : _amounts(p.history),
                    key: const Key('move-history'),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Change to your account card balances:',
                    style: label,
                  ),
                  Text(_cardsText(p), key: const Key('move-cards')),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _working ? null : _apply,
                    child: Text('Back up and fix ${p.changes.length}'),
                  ),
                ],
                if (_changed.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: _working ? null : _undo,
                    child: Text('Undo the fix (${_changed.length})'),
                  ),
                ],
                if (_log.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text('Run log (saved on this phone)', style: label),
                  for (final line in _log)
                    Text(line, style: const TextStyle(fontSize: 12)),
                ],
                if (_working) ...[
                  const SizedBox(height: 16),
                  const Center(child: CircularProgressIndicator()),
                ],
              ],
            ),
    );
  }
}
