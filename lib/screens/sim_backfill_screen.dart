import 'package:flutter/material.dart';

import '../accounts/money_account.dart';
import '../maintenance/sim_backfill.dart';
import '../maintenance/ziidi_fix.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';

/// Needs review › Account › "Fill in SIMs from your messages": shows which
/// SMS records with no account can get one (their SIM recorded at import,
/// or found in this phone's messages by code), how every account card
/// would change, and what's left alone. Writes only after a confirmation,
/// with a backup first; Undo removes exactly what it set.
class SimBackfillScreen extends StatefulWidget {
  const SimBackfillScreen({super.key, required this.backfill});

  final SimBackfill backfill;

  @override
  State<SimBackfillScreen> createState() => _SimBackfillScreenState();
}

class _SimBackfillScreenState extends State<SimBackfillScreen> {
  BackfillPreview? _preview;
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
      final preview = await widget.backfill.preview();
      final changed = await widget.backfill.changedIds();
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
    Future<ZiidiRunResult> Function() job,
    String Function(ZiidiRunResult) describe,
  ) async {
    if (_working) return;
    setState(() => _working = true);
    final r = await job();
    if (!mounted) return;
    setState(() => _working = false);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(describe(r))));
    await _load();
  }

  /// Applies one group only, after showing its records' count, the past
  /// totals they carry and the change (usually none) to the card balances.
  Future<void> _apply(SimEvidence e) async {
    final p = _preview!.only(e);
    if (!await _confirm(
      'Give ${p.changes.length} transactions their account?',
      '${BackfillWording.groupName(e)}.\n\n'
          '${BackfillWording.historyTitle}\n${BackfillWording.history(p)}\n\n'
          '${BackfillWording.cardsTitle}\n${BackfillWording.cards(p)}\n\n'
          '${BackfillWording.whatChanges}\n\n'
          'A backup is saved on this phone first, and you can undo this.',
      'Back up and assign',
    )) {
      return;
    }
    await _run(
      () => widget.backfill.apply(p),
      (r) => r.error == null
          ? 'Assigned ${r.done}${r.skipped > 0 ? ' (${r.skipped} changed since, left as they were)' : ''}.'
          : 'Stopped after ${r.done}: ${r.error}',
    );
  }

  /// One group: past totals, card balance change, its records (date,
  /// amount, type → account) and its own button.
  List<Widget> _group(BackfillPreview all, SimEvidence e) {
    final p = all.only(e);
    const label = TextStyle(fontWeight: FontWeight.w600, fontSize: 13);
    return [
      const SizedBox(height: 16),
      Text(
        '${BackfillWording.groupName(e)}: ${p.changes.length}',
        key: Key('backfill-${e.name}'),
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 4),
      const Text(BackfillWording.historyTitle, style: label),
      Text(BackfillWording.history(p), key: Key('backfill-${e.name}-history')),
      const SizedBox(height: 4),
      const Text(BackfillWording.cardsTitle, style: label),
      Text(BackfillWording.cards(p), key: Key('backfill-${e.name}-cards')),
      const SizedBox(height: 4),
      for (final c in p.changes.take(300))
        Text(
          '${Formatters.shortDate(c.record.date)} · '
          '${Formatters.currency(c.record.amount)} · ${c.record.type} → '
          '${c.accountName ?? c.accountId}${c.setsSim ? ' (SIM ${c.simSlot + 1})' : ''}',
          style: TextStyle(fontSize: 12, color: context.colors.textSecondary),
        ),
      if (p.changes.length > 300)
        Text(
          '…and ${p.changes.length - 300} more',
          style: const TextStyle(fontSize: 12),
        ),
      const SizedBox(height: 8),
      FilledButton(
        onPressed: _working || p.changes.isEmpty ? null : () => _apply(e),
        child: Text('Back up and assign ${p.changes.length}'),
      ),
    ];
  }

  Future<void> _undo() async {
    if (!await _confirm(
      'Undo the SIM fill-in?',
      'The ${_changed.length} transactions it gave an account lose it again. '
          'Any you edited since are left alone.',
      'Undo',
    )) {
      return;
    }
    await _run(
      widget.backfill.undo,
      (r) => r.error == null
          ? 'Undone ${r.done}${r.skipped > 0 ? ' (${r.skipped} edited since, left as they are)' : ''}.'
          : 'Stopped after ${r.done}: ${r.error}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = _preview;
    return Scaffold(
      appBar: AppBar(title: const Text('Fill in SIMs')),
      body: _error != null
          ? Center(child: Text(_error!))
          : p == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'SMS transactions with no account, given the account of '
                  'the SIM they came to. The SIM is never guessed. '
                  'Nothing has been changed yet.',
                  style: TextStyle(color: context.colors.textSecondary),
                ),
                const SizedBox(height: 8),
                const Text(
                  BackfillWording.whatChanges,
                  key: Key('backfill-what-changes'),
                ),
                const SizedBox(height: 12),
                Text(
                  'Ready: ${p.changes.length}',
                  key: const Key('backfill-ready'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  'SIM recorded when imported: '
                  '${p.count(SimEvidence.stored)}',
                ),
                Text(
                  'SIM found in this phone\'s messages: '
                  '${p.count(SimEvidence.inbox)}',
                ),
                const SizedBox(height: 8),
                for (final e in p.skipped.entries)
                  Text(
                    'Left alone, ${e.key.toLowerCase()}: ${e.value}',
                    style: TextStyle(color: context.colors.textSecondary),
                  ),
                // Each group is applied on its own.
                ..._group(p, SimEvidence.stored),
                ..._group(p, SimEvidence.inbox),
                const SizedBox(height: 8),
                if (_changed.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: _working ? null : _undo,
                    child: Text('Undo the fill-in (${_changed.length})'),
                  ),
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

/// The preview's wording, kept apart so past totals are never presented as
/// a change to the balance a card shows.
class BackfillWording {
  BackfillWording._();

  static String groupName(SimEvidence e) => switch (e) {
    SimEvidence.stored => 'SIM recorded when imported',
    SimEvidence.inbox => 'SIM found in this phone\'s messages',
  };

  static const whatChanges =
      'Assigning an account only records which account each transaction '
      'belongs to. It doesn\'t add, remove or move money, and amounts, '
      'categories, types, fees, dates and codes stay the same.';

  static const historyTitle =
      'Past income minus spending in these records (not a balance change):';

  static const cardsTitle = 'Change to your account card balances:';

  static String _amounts(Map<MoneyAccount, double> m) => [
    for (final e in m.entries)
      '${e.key.name}: ${e.value > 0 ? '+' : ''}${Formatters.currency(e.value)}',
  ].join('\n');

  /// The income minus spending the records add to each account's history.
  static String history(BackfillPreview p) => p.impact.isEmpty
      ? 'None. These are already counted on their account.'
      : _amounts(p.impact);

  /// What the cards (and Home) would actually show differently.
  static String cards(BackfillPreview p) {
    if (p.cardChange.isNotEmpty) return _amounts(p.cardChange);
    return p.impact.isEmpty
        ? 'No change. These are already counted in their account balances.'
        : 'No change. Your cards use newer M-Pesa balance messages, which '
              'already include these transactions.';
  }
}
