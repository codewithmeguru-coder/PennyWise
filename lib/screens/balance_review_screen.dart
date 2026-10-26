import 'package:flutter/material.dart';

import '../accounts/account_balances.dart';
import '../accounts/account_repository.dart';
import '../accounts/anchor_log.dart';
import '../accounts/balance_assessment.dart';
import '../accounts/money_account.dart';
import '../data/data_exception.dart';
import '../models/transaction_model.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';

/// One account's balance, laid out so the user can see where it comes from:
/// starting balance, transactions since, the latest SMS balance and any
/// difference. From here the user can make the SMS balance the new starting
/// point (logged, with Undo). Nothing changes without a tap and a
/// confirmation, and no transaction is ever created to make figures match.
class BalanceReviewScreen extends StatefulWidget {
  const BalanceReviewScreen({
    super.key,
    required this.accountId,
    required this.accounts,
    required this.transactions,
    this.keeper,
  });

  final String accountId;
  final AccountStore accounts;
  final List<TransactionModel> transactions;
  final AnchorKeeper? keeper;

  @override
  State<BalanceReviewScreen> createState() => _BalanceReviewScreenState();
}

class _BalanceReviewScreenState extends State<BalanceReviewScreen> {
  List<AnchorChange> _history = const [];
  AnchorChange? _undoable;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    final keeper = widget.keeper;
    if (keeper == null) return;
    final List<AnchorChange> history;
    final AnchorChange? undoable;
    try {
      history = await keeper.history(widget.accountId);
      undoable = await keeper.undoable(widget.accountId);
    } on DataException catch (e) {
      // e.g. offline: the figures above still work; say why there's no
      // history rather than showing an empty one.
      if (mounted) _message('History unavailable: ${e.message}');
      return;
    }
    if (!mounted) return;
    setState(() {
      _history = history;
      _undoable = undoable;
    });
  }

  void _message(String text) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(text)));

  Future<void> _useSms(AccountBalance b) async {
    final keeper = widget.keeper;
    if (keeper == null || _working) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Use the SMS balance?'),
        content: Text(
          'The starting balance of ${b.account.name} becomes '
          '${Formatters.currency(b.reported!)} as of the SMS of '
          '${Formatters.shortDate(b.reportedAt!)}. Transactions are not '
          'changed, and only newer ones count from then on. You can undo '
          'this.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Use it'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _working = true);
    try {
      final saved = await keeper.change(
        b.account.copyWith(
          openingBalance: b.reported,
          // Just after the message: its own transaction is in the figure.
          openingDate: b.reportedAt!.add(const Duration(milliseconds: 1)),
        ),
        reason: 'Used SMS balance',
      );
      _message(saved
          ? 'Starting balance updated'
          : 'Already saved: nothing changed.');
    } on DataException catch (e) {
      _message(e.message);
    }
    if (!mounted) return;
    setState(() => _working = false);
    await _loadHistory();
  }

  Future<void> _undo() async {
    final keeper = widget.keeper;
    if (keeper == null || _working) return;
    setState(() => _working = true);
    try {
      final done = await keeper.undo(widget.accountId);
      _message(done
          ? 'Previous starting balance restored'
          : 'Nothing to undo: the starting balance changed since.');
    } on DataException catch (e) {
      _message(e.message);
    }
    if (!mounted) return;
    setState(() => _working = false);
    await _loadHistory();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.accounts,
      builder: (context, _) {
        final account = widget.accounts.byId(widget.accountId);
        if (account == null) {
          return const Scaffold(body: Center(child: Text('Account not found')));
        }
        final b = AccountBalance.of(account, widget.transactions);
        return Scaffold(
          appBar: AppBar(title: Text(account.name)),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              ..._figures(b),
              const SizedBox(height: 12),
              _StatusBox(balance: b),
              if (b.differs) ...[
                const SizedBox(height: 12),
                ..._causes(b),
              ],
              if (b.reported != null &&
                  widget.keeper != null &&
                  (b.differs || !b.hasOpening)) ...[
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _working ? null : () => _useSms(b),
                  child: const Text('Use the SMS balance as starting point'),
                ),
              ],
              if (_undoable != null) ...[
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: _working ? null : _undo,
                  child: Text('Undo "${_undoable!.reason}"'),
                ),
              ],
              if (_history.isNotEmpty) ...[
                const SizedBox(height: 20),
                const Text('Starting balance history',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                for (final h in _history.reversed)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text('${h.reason}${h.undone ? ' (undone)' : ''}'),
                    subtitle: Text(
                      '${_amount(account, h.before)} → '
                      '${_amount(account, h.after)} · '
                      '${Formatters.shortDate(h.at)}',
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }

  String _amount(MoneyAccount a, double? v) => v == null
      ? 'not set'
      : a.kind == AccountKind.loan
          ? '${Formatters.currency(-v + 0)} owed'
          : Formatters.currency(v);

  List<Widget> _figures(AccountBalance b) {
    final a = b.account;
    final isLoan = a.kind == AccountKind.loan;
    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(label,
                    style: const TextStyle(color: AppColors.textSecondary)),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(value,
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        );
    final since = a.openingDate;
    final countSince = widget.transactions
        .where((t) =>
            AccountBalance.belongs(a, t) &&
            (since == null || !t.date.isBefore(since)))
        .length;
    return [
      row(
        'Starting balance',
        a.openingBalance == null
            ? 'not set'
            : '${_amount(a, a.openingBalance)} · '
                '${Formatters.shortDate(since!)}',
      ),
      row(since == null ? 'Transactions recorded' : 'Transactions since',
          '$countSince'),
      row(isLoan ? 'Owed now (calculated)' : 'PennyWise balance',
          Formatters.currency(isLoan ? b.owed : b.shown)),
      if (b.reported != null) ...[
        row('Latest SMS balance',
            '${Formatters.currency(b.reported!)} · '
                '${Formatters.shortDate(b.reportedAt!)}'),
        if (b.calculatedAtReport != null)
          row('PennyWise at that time',
              Formatters.currency(b.calculatedAtReport!)),
        if (b.difference != null)
          row('Difference', Formatters.currency(b.difference!)),
      ],
    ];
  }

  List<Widget> _causes(AccountBalance b) {
    final a = b.account;
    final since = a.openingDate;
    final noSim = widget.transactions
        .where((t) =>
            t.isDetected &&
            t.simSlot == null &&
            t.accountId == null &&
            (since == null || !t.date.isBefore(since)))
        .length;
    final causes = [
      'A message is missing (deleted, never received, or from before '
          'detection was on).',
      if (noSim > 0)
        '$noSim messages since the starting balance have no SIM, so they '
            'aren\'t on this account.',
      'A transaction is on the other SIM, or recorded twice.',
      'A fee, transfer or Fuliza loan isn\'t recorded.',
      'The starting balance was entered for a different time.',
    ];
    return [
      const Text('Possible reasons',
          style: TextStyle(fontWeight: FontWeight.w600)),
      for (final c in causes)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('• $c'),
        ),
    ];
  }
}

class _StatusBox extends StatelessWidget {
  const _StatusBox({required this.balance});

  final AccountBalance balance;

  @override
  Widget build(BuildContext context) {
    final (icon, color, text) = switch (balance.status) {
      BalanceStatus.verified => (
          Icons.verified_rounded,
          AppColors.income,
          'Matches the latest SMS.'
        ),
      BalanceStatus.mismatch => (
          Icons.warning_amber_rounded,
          AppColors.warning,
          'The latest SMS doesn\'t match PennyWise. Your balance has not been '
              'changed.'
        ),
      BalanceStatus.anchored => (
          Icons.flag_outlined,
          AppColors.textSecondary,
          'From your starting balance. No SMS since then to check it with.'
        ),
      BalanceStatus.fromSms => (
          Icons.sms_outlined,
          AppColors.textSecondary,
          'No starting balance: taken from the latest SMS and what happened '
              'after it.'
        ),
      BalanceStatus.unverified => (
          Icons.help_outline_rounded,
          AppColors.warning,
          'Not verified: no starting balance and no SMS balance. This only '
              'adds up recorded transactions, which may be incomplete.'
        ),
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
      ],
    );
  }
}

/// The read-only balance check: what makes balances unreliable, and the
/// proposed next steps. Nothing on this screen changes any data.
class BalanceAssessmentScreen extends StatelessWidget {
  const BalanceAssessmentScreen({super.key, required this.findings});

  final List<BalanceFinding> findings;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Check balances')),
      body: findings.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Nothing found: every balance has a starting '
                    'point and agrees with the latest SMS.'),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Nothing here changes your data. Each item says what to do '
                  'next.',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
                for (final f in findings)
                  Card(
                    margin: const EdgeInsets.only(top: 12),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(f.title,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 4),
                          Text(f.detail),
                          const SizedBox(height: 6),
                          Text('Next: ${f.action}',
                              style: const TextStyle(
                                  color: AppColors.textSecondary)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
