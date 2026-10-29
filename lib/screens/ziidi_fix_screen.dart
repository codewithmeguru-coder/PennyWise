import 'package:flutter/material.dart';

import '../maintenance/ziidi_fix.dart';
import '../maintenance/ziidi_matcher.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';

/// Settings › Fix old Ziidi records: shows which older records are really
/// Ziidi savings moves, changes them only after a confirmation (with a
/// backup first), and can undo exactly what it changed.
class ZiidiFixScreen extends StatefulWidget {
  const ZiidiFixScreen({super.key, required this.fixer});

  final ZiidiFixer fixer;

  @override
  State<ZiidiFixScreen> createState() => _ZiidiFixScreenState();
}

class _ZiidiFixScreenState extends State<ZiidiFixScreen> {
  ZiidiPreview? _preview;
  List<String> _changed = const [];
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
      final preview = await widget.fixer.preview();
      final changed = await widget.fixer.changedIds();
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _changed = changed;
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
          content: Text(text),
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

  Future<void> _run(Future<ZiidiRunResult> Function() job,
      String Function(ZiidiRunResult) describe) async {
    if (_working) return;
    setState(() => _working = true);
    final r = await job();
    if (!mounted) return;
    setState(() => _working = false);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(describe(r))));
    await _load();
  }

  Future<void> _fix() async {
    final p = _preview!;
    if (!await _confirm(
        'Fix ${p.changes.length} Ziidi records?',
        '${p.contributions} become savings deposits and ${p.withdrawals} '
            'savings withdrawals. Amounts, dates and M-Pesa codes don\'t '
            'change. A backup is saved first, and you can undo this.',
        'Fix')) {
      return;
    }
    await _run(
      () => widget.fixer.fix(p),
      (r) => r.error == null
          ? 'Fixed ${r.done}${r.skipped > 0 ? ' (${r.skipped} left as they were)' : ''}.'
          : 'Stopped after ${r.done}: ${r.error}',
    );
  }

  /// A real Ziidi deposit or withdrawal the user edited after import is
  /// fixed only on its own explicit confirmation.
  Future<void> _fixEdited() async {
    final p = _preview!;
    final e = p.edited;
    if (!await _confirm(
        'Fix ${e.length} record${e.length == 1 ? '' : 's'} you edited?',
        '${e.length == 1 ? 'This record is' : 'These records are'} a real '
            'Ziidi ${e.length == 1 ? 'move' : 'moves'} by ${e.length == 1 ? 'its' : 'their'} '
            'message, but ${e.length == 1 ? 'was' : 'were'} edited after import and '
            '${e.length == 1 ? 'is' : 'are'} still saved as '
            '${e.map((c) => c.record.type).toSet().join(' / ')}. '
            'Fixing makes ${e.length == 1 ? 'it' : 'them'} savings, so '
            'spending drops by ${Formatters.currency(e.where((c) => c.check.direction == ZiidiDirection.sent).fold(0.0, (s, c) => s + c.record.amount))}. '
            'The amount, date and M-Pesa code don\'t change. A backup is '
            'saved first, and Undo puts ${e.length == 1 ? 'it' : 'them'} back.',
        'Fix')) {
      return;
    }
    await _run(
      () => widget.fixer.fixEdited(p),
      (r) => r.error == null
          ? 'Fixed ${r.done}${r.skipped > 0 ? ' (${r.skipped} changed since, left as they were)' : ''}.'
          : 'Stopped after ${r.done}: ${r.error}',
    );
  }

  Future<void> _undo() async {
    if (!await _confirm(
        'Undo the Ziidi fix?',
        'The ${_changed.length} records it changed go back to how they were. '
            'Records you edited since are left alone.',
        'Undo')) {
      return;
    }
    await _run(
      widget.fixer.undo,
      (r) => r.error == null
          ? 'Restored ${r.done}${r.skipped > 0 ? ' (${r.skipped} edited since, left as they are)' : ''}.'
          : 'Stopped after ${r.done}: ${r.error}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = _preview;
    return Scaffold(
      appBar: AppBar(title: const Text('Fix old Ziidi records')),
      body: _error != null
          ? Center(child: Text(_error!))
          : p == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    const Text(
                      'Older Ziidi deposits and withdrawals were saved as '
                      'spending and income. Nothing has been changed yet.',
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                    const SizedBox(height: 12),
                    Text('Savings deposits: ${p.contributions} '
                        '(${Formatters.currency(p.contributed)})'),
                    Text('Savings withdrawals: ${p.withdrawals} '
                        '(${Formatters.currency(p.withdrawn)})'),
                    Text('SIM known from the phone: ${p.withSim} of '
                        '${p.changes.length}; the rest stay "SIM unknown".'),
                    for (final e in p.skipped.entries)
                      Text('Left alone, ${e.key.toLowerCase()}: ${e.value}',
                          style:
                              const TextStyle(color: AppColors.textSecondary)),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed:
                          _working || p.changes.isEmpty ? null : _fix,
                      child: Text('Back up and fix ${p.changes.length}'),
                    ),
                    if (p.edited.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text(
                        '${p.edited.length} real Ziidi '
                        '${p.edited.length == 1 ? 'record was' : 'records were'} '
                        'edited by you after import, so the fix leaves '
                        '${p.edited.length == 1 ? 'it' : 'them'} alone:',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      for (final c in p.edited)
                        Text('${Formatters.shortDate(c.record.date)} · '
                            '${Formatters.currency(c.record.amount)} · saved as '
                            '${c.record.type} / ${c.record.category}'),
                      const SizedBox(height: 8),
                      OutlinedButton(
                        onPressed: _working ? null : _fixEdited,
                        child: Text(p.edited.length == 1
                            ? 'Fix this one too…'
                            : 'Fix these ${p.edited.length} too…'),
                      ),
                    ],
                    if (_changed.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      OutlinedButton(
                        onPressed: _working ? null : _undo,
                        child: Text('Undo the fix (${_changed.length})'),
                      ),
                    ],
                    if (_working) ...[
                      const SizedBox(height: 16),
                      const Center(child: CircularProgressIndicator()),
                    ],
                    const SizedBox(height: 16),
                    for (final c in p.changes.take(200))
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                            '${Formatters.shortDate(c.record.date)} · '
                            '${Formatters.currency(c.record.amount)}'),
                        subtitle: Text(
                            '${c.record.type} → '
                            '${c.check.direction == ZiidiDirection.sent ? 'savings deposit' : 'savings withdrawal'}'
                            '${c.simSlot == null ? ' · SIM unknown' : ' · SIM ${c.simSlot! + 1}'}'),
                      ),
                  ],
                ),
    );
  }
}
