import 'package:flutter/material.dart';

import '../accounts/account_repository.dart';
import '../accounts/account_balances.dart';
import '../accounts/anchor_log.dart';
import '../accounts/balance_assessment.dart';
import '../accounts/money_account.dart';
import '../models/transaction_model.dart';
import '../data/data_exception.dart';
import '../privacy/savings_privacy.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';
import '../utils/validators.dart';
import 'balance_review_screen.dart';

/// Settings › Accounts: the user's own accounts. Rename, set a starting
/// balance, hide, or add a bank / cash / other account. Accounts are never
/// deleted here, so no transaction loses its account.
class AccountsScreen extends StatelessWidget {
  const AccountsScreen({
    super.key,
    required this.accounts,
    this.transactions,
    this.keeper,
  });

  final AccountStore accounts;

  /// The user's transactions, for balances, SMS suggestions and checks.
  final List<TransactionModel> Function()? transactions;

  /// Changes starting balances with an audit trail and Undo. Without it
  /// (older callers, tests) accounts are saved directly.
  final AnchorKeeper? keeper;

  List<TransactionModel> get _txs => transactions?.call() ?? const [];

  Future<void> _store(MoneyAccount updated, String reason) async {
    final before = accounts.byId(updated.id);
    final anchorChanged = before != null &&
        (before.openingBalance != updated.openingBalance ||
            before.openingDate != updated.openingDate);
    if (keeper != null && anchorChanged) {
      await keeper!.change(updated, reason: reason);
    } else {
      await accounts.save(updated);
    }
  }

  Future<void> _edit(BuildContext context, [MoneyAccount? existing]) async {
    final result = await Navigator.of(context).push<MoneyAccount>(
      MaterialPageRoute(
        builder: (_) => AccountEditorScreen(
          existing: existing,
          takenIds: accounts.all.map((a) => a.id).toSet(),
        ),
      ),
    );
    if (result == null || !context.mounted) return;
    try {
      await _store(result, 'Edited');
    } on DataException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<void> _startOver(BuildContext context) async {
    final result = await Navigator.of(context).push<List<MoneyAccount>>(
      MaterialPageRoute(
        // Hidden ones too, so showing one again later doesn't bring back
        // its older history.
        builder: (_) =>
            StartOverScreen(accounts: accounts.all, transactions: _txs),
      ),
    );
    if (result == null || !context.mounted) return;
    try {
      for (final a in result) {
        await _store(a, 'Start over');
      }
    } on DataException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Accounts'),
        actions: [
          if (accounts.all.isNotEmpty && transactions != null)
            IconButton(
              tooltip: 'Check balances',
              icon: const Icon(Icons.fact_check_outlined),
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => BalanceAssessmentScreen(
                  findings: BalanceAssessment.of(accounts.all, _txs),
                ),
              )),
            ),
          if (accounts.all.isNotEmpty)
            TextButton(
              onPressed: () => _startOver(context),
              child: const Text('Start over'),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context),
        icon: const Icon(Icons.add),
        label: const Text('Add account'),
      ),
      body: ListenableBuilder(
        listenable: accounts,
        builder: (context, _) {
          final list = accounts.all;
          if (list.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: FilledButton(
                  onPressed: accounts.createStarterSet,
                  child: const Text('Create SIM 1, SIM 2 and Cash accounts'),
                ),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  'M-Pesa messages go to the account of the SIM that '
                  'received them. SIM 1 and SIM 2 are always kept separate. '
                  'Only add accounts that are yours.',
                  style: TextStyle(color: context.colors.textSecondary),
                ),
              ),
              for (final a in list)
                ListTile(
                  title: Text(a.name),
                  subtitle: Text([
                    a.kind.label,
                    if (a.simLabel != null) a.simLabel!,
                    if (a.openingBalance != null)
                      a.kind == AccountKind.loan
                          ? 'Owed ${Formatters.currency(-a.openingBalance! + 0)}'
                          : 'Starting balance '
                              '${a.kind == AccountKind.savings ? SavingsPrivacy.amount(context, a.openingBalance!) : Formatters.currency(a.openingBalance!)}',
                    if (!a.active) 'Hidden',
                  ].join(' · ')),
                  trailing: transactions == null
                      ? const Icon(Icons.edit_outlined)
                      : IconButton(
                          tooltip: 'Check balance',
                          icon: const Icon(Icons.manage_search_rounded),
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => BalanceReviewScreen(
                                accountId: a.id,
                                accounts: accounts,
                                transactions: _txs,
                                keeper: keeper,
                              ),
                            ),
                          ),
                        ),
                  onTap: () => _edit(context, a),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Add or edit one account. Pops with the result, or null.
class AccountEditorScreen extends StatefulWidget {
  const AccountEditorScreen({
    super.key,
    this.existing,
    this.takenIds = const {},
  });

  final MoneyAccount? existing;
  final Set<String> takenIds;

  @override
  State<AccountEditorScreen> createState() => _AccountEditorScreenState();
}

class _AccountEditorScreenState extends State<AccountEditorScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name =
      TextEditingController(text: widget.existing?.name ?? '');
  /// A loan (Fuliza) is entered as the amount owed and stored as a
  /// negative balance, so repayments bring it back up towards 0.
  bool get _isLoan => widget.existing?.kind == AccountKind.loan;

  late final TextEditingController _opening = TextEditingController(
      text: switch (widget.existing?.openingBalance) {
        null => '',
        final b => (_isLoan && b != 0 ? -b : b).toStringAsFixed(2),
      });
  late AccountKind _kind = widget.existing?.kind ?? AccountKind.bank;
  late AccountProvider _provider =
      widget.existing?.provider ?? AccountProvider.equity;
  /// When the starting balance applies. Null means "now" (when saved).
  late DateTime? _openingDate = widget.existing?.openingDate;

  /// The user chose [_openingDate] on purpose. Until then, typing a new
  /// amount resets it to now: a balance typed today is today's balance, so
  /// transactions since an older date must not be added on top of it.
  bool _datePicked = false;
  late bool _active = widget.existing?.active ?? true;

  bool get _isNew => widget.existing == null;

  @override
  void dispose() {
    _name.dispose();
    _opening.dispose();
    super.dispose();
  }

  String _newId() {
    final base = _name.text
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    var id = base.isEmpty ? 'account' : base;
    if (id.length > 40) id = id.substring(0, 40);
    var n = 2;
    final taken = widget.takenIds;
    var candidate = id;
    while (taken.contains(candidate)) {
      candidate = '$id-${n++}';
    }
    return candidate;
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _openingDate ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() {
        _openingDate = picked;
        _datePicked = true;
      });
    }
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    final entered = _opening.text.trim().isEmpty
        ? null
        : double.parse(_opening.text.trim());
    final opening = _isLoan && entered != null && entered != 0
        ? -entered
        : entered;
    final existing = widget.existing;
    final result = existing == null
        ? MoneyAccount(
            id: _newId(),
            name: _name.text.trim(),
            kind: _kind,
            provider: _kind == AccountKind.bank
                ? _provider
                : AccountProvider.none,
            openingBalance: opening,
            openingDate: opening == null ? null : (_openingDate ?? DateTime.now()),
            order: 100,
          )
        : MoneyAccount(
            id: existing.id,
            name: _name.text.trim(),
            kind: existing.kind,
            provider: existing.provider,
            simSlot: existing.simSlot,
            parentId: existing.parentId,
            openingBalance: opening,
            openingDate:
                opening == null ? null : (_openingDate ?? DateTime.now()),
            active: _active,
            order: existing.order,
          );
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.existing;
    return Scaffold(
      appBar: AppBar(title: Text(_isNew ? 'Add account' : 'Edit account')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_isNew) ...[
              DropdownButtonFormField<AccountKind>(
                initialValue: _kind,
                decoration: const InputDecoration(labelText: 'Type'),
                items: [
                  for (final k in [AccountKind.bank, AccountKind.cash])
                    DropdownMenuItem(value: k, child: Text(k.label)),
                ],
                onChanged: (k) => setState(() => _kind = k ?? _kind),
              ),
              if (_kind == AccountKind.bank) ...[
                const SizedBox(height: 16),
                DropdownButtonFormField<AccountProvider>(
                  initialValue: _provider,
                  decoration: const InputDecoration(labelText: 'Bank'),
                  items: [
                    for (final p in [
                      AccountProvider.equity,
                      AccountProvider.otherBank,
                    ])
                      DropdownMenuItem(value: p, child: Text(p.label)),
                  ],
                  onChanged: (p) => setState(() => _provider = p ?? _provider),
                ),
              ],
              const SizedBox(height: 16),
            ] else
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  [existing!.kind.label, ?existing.simLabel].join(' · '),
                  style: TextStyle(color: context.colors.textSecondary),
                ),
              ),
            TextFormField(
              controller: _name,
              maxLength: 40,
              decoration: const InputDecoration(labelText: 'Name'),
              validator: (v) => Validators.requiredText(v,
                  emptyMessage: 'Enter a name', max: 40),
            ),
            TextFormField(
              controller: _opening,
              onChanged: (_) {
                if (!_datePicked && _openingDate != null) {
                  setState(() => _openingDate = null);
                }
              },
              keyboardType: const TextInputType.numberWithOptions(
                  decimal: true, signed: true),
              decoration: InputDecoration(
                labelText: _isLoan
                    ? 'Amount owed (optional)'
                    : 'Starting balance (optional)',
                helperText: _isLoan
                    ? 'What you owe on this date, e.g. 261.71; 0 if nothing.'
                    : 'Can be 0 or negative. Without it, the balance is an '
                        'estimate.',
                helperMaxLines: 2,
                prefixText: '${Formatters.currencySymbol} ',
              ),
              validator: (v) => _isLoan && (v ?? '').trim().startsWith('-')
                  ? 'Enter the amount owed, without a minus'
                  : Validators.optionalBalance(v),
            ),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(_isLoan ? 'Owed on' : 'Starting balance date'),
              subtitle: Text(_openingDate == null
                  ? 'Now (when you save)'
                  : Formatters.shortDate(_openingDate!)),
              trailing: const Icon(Icons.calendar_today_rounded),
              onTap: _pickDate,
            ),
            if (!_isNew)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Show this account'),
                subtitle: const Text('Hiding keeps its transactions.'),
                value: _active,
                onChanged: (v) => setState(() => _active = v),
              ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _save, child: const Text('Save')),
          ],
        ),
      ),
    );
  }
}

/// "Start balances over": the user types each account's real balance now
/// (Fuliza as the amount owed). From this moment the account cards, and
/// Home's balance and savings, count only newer transactions. Nothing is
/// deleted: older transactions stay in the history and reports. Pops with
/// the changed accounts, or null.
class StartOverScreen extends StatefulWidget {
  const StartOverScreen({
    super.key,
    required this.accounts,
    this.transactions = const [],
    this.title = 'Start balances over',
  });

  final List<MoneyAccount> accounts;

  /// Used to offer each M-Pesa account's latest SMS balance.
  final List<TransactionModel> transactions;
  final String title;

  @override
  State<StartOverScreen> createState() => _StartOverScreenState();
}

class _StartOverScreenState extends State<StartOverScreen> {
  final _form = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _fields = {
    for (final a in widget.accounts) a.id: TextEditingController(),
  };

  /// Accounts set from an SMS balance: that balance is as of the message,
  /// so the anchor is just after it (the message's own transaction is
  /// already in the figure). Typed amounts are as of now.
  final _fromSms = <String, DateTime>{};
  late final _sms = {
    for (final a in widget.accounts)
      a.id: ?AccountBalance.latestSmsBalance(a, widget.transactions),
  };

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    final now = DateTime.now();
    Navigator.of(context).pop([
      for (final a in widget.accounts)
        if (_fields[a.id]!.text.trim() case final text when text.isNotEmpty)
          a.copyWith(
            openingBalance: switch (double.parse(text)) {
              0 => 0,
              // Fuliza is typed as the amount owed: a negative balance.
              final v => a.kind == AccountKind.loan ? -v : v,
            },
            openingDate: switch (_fromSms[a.id]) {
              final at? => at.add(const Duration(milliseconds: 1)),
              null => now,
            },
          ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Type what each account holds right now (check M-Pesa, Ziidi '
              'and your bank), or use the balance from its latest SMS. For '
              'Fuliza, type what you owe, not your limit. From then on the '
              'balances count only newer transactions; older ones stay in '
              'your history and reports. Leave a box empty to skip: that '
              'account stays marked as not verified.',
              style: TextStyle(color: context.colors.textSecondary),
            ),
            const SizedBox(height: 8),
            for (final a in widget.accounts)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                TextFormField(
                  controller: _fields[a.id],
                  onChanged: (_) => setState(() => _fromSms.remove(a.id)),
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true, signed: true),
                  decoration: InputDecoration(
                    labelText: [
                      a.kind == AccountKind.loan
                          ? '${a.name}: amount owed'
                          : a.name,
                      if (!a.active) ' (hidden)',
                    ].join(),
                    prefixText: '${Formatters.currencySymbol} ',
                  ),
                  validator: (v) =>
                      a.kind == AccountKind.loan &&
                              (v ?? '').trim().startsWith('-')
                          ? 'Enter the amount owed, without a minus'
                          : Validators.optionalBalance(v),
                ),
                if (_sms[a.id] case final s?)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: _fromSms.containsKey(a.id)
                        ? Text(
                            'As of the SMS of ${Formatters.shortDate(s.at)}',
                            style: TextStyle(
                                color: context.colors.textSecondary, fontSize: 12),
                          )
                        : ActionChip(
                            avatar: const Icon(Icons.sms_outlined, size: 16),
                            label: Text('Use SMS balance '
                                '${Formatters.currency(s.amount)} '
                                '(${Formatters.shortDate(s.at)})'),
                            onPressed: () => setState(() {
                              _fields[a.id]!.text = s.amount.toStringAsFixed(2);
                              _fromSms[a.id] = s.at;
                            }),
                          ),
                  ),
                  ],
                ),
              ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _save,
              child: const Text('Start over from now'),
            ),
          ],
        ),
      ),
    );
  }
}
