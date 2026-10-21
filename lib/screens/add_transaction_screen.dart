import 'package:flutter/material.dart';

import '../models/transaction_category.dart';
import '../models/transaction_model.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';
import '../utils/validators.dart';

/// What [AddTransactionScreen] returns via `Navigator.pop`.
sealed class TransactionFormResult {
  const TransactionFormResult(this.transaction);

  final TransactionModel transaction;
}

/// The user saved the form (a new transaction, or edits to an existing one).
class TransactionSaved extends TransactionFormResult {
  const TransactionSaved(super.transaction);
}

/// The user chose to delete the transaction being edited.
class TransactionDeleted extends TransactionFormResult {
  const TransactionDeleted(super.transaction);
}

/// Full-screen form for adding any kind of transaction, or editing one.
///
/// It doesn't save anything itself: it closes and returns a
/// [TransactionFormResult] via `Navigator.pop`, and the caller writes it to
/// the store.
class AddTransactionScreen extends StatefulWidget {
  const AddTransactionScreen({super.key, this.initial});

  /// The transaction to edit, or null to add a new one.
  final TransactionModel? initial;

  @override
  State<AddTransactionScreen> createState() => _AddTransactionScreenState();
}

class _AddTransactionScreenState extends State<AddTransactionScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _amountController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _noteController;
  late final TextEditingController _feeController;
  late final TextEditingController _interestController;

  late TransactionType _type;
  String? _categoryId;
  bool _showCategoryError = false;
  late DateTime _date;

  /// Null only for older transactions saved before accounts existed.
  Account? _account;

  /// Transfers only: where the money went.
  Account? _toAccount;

  bool get _isEditing => widget.initial != null;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _amountController = TextEditingController(
      text: initial == null ? '' : _formatAmount(initial.amount),
    );
    _descriptionController =
        TextEditingController(text: initial?.description ?? '');
    _noteController = TextEditingController(text: initial?.note ?? '');
    _feeController = TextEditingController(
      text: initial?.fee == null ? '' : _formatAmount(initial!.fee!),
    );
    _interestController = TextEditingController(
      text: initial?.interest == null ? '' : _formatAmount(initial!.interest!),
    );
    _type = initial?.type ?? TransactionType.expense;
    _categoryId = initial?.categoryId;
    _date = initial?.date ?? DateTime.now();
    // New entries start on M-Pesa, the most common account. Older entries
    // keep "Not set" unless the SMS they came from says which account.
    _account = initial == null ? Account.mpesa : initial.effectiveAccount;
    _toAccount = initial?.toAccount;
  }

  /// 850.0 -> "850", 12.5 -> "12.50"
  static String _formatAmount(double amount) => amount == amount.roundToDouble()
      ? amount.toStringAsFixed(0)
      : amount.toStringAsFixed(2);

  @override
  void dispose() {
    _amountController.dispose();
    _descriptionController.dispose();
    _noteController.dispose();
    _feeController.dispose();
    _interestController.dispose();
    super.dispose();
  }

  Color get _accent => switch (_type) {
        TransactionType.income || TransactionType.refund => AppColors.income,
        TransactionType.expense ||
        TransactionType.debtRepayment =>
          AppColors.expense,
        TransactionType.transfer => AppColors.neutral,
        TransactionType.savingsContribution ||
        TransactionType.savingsWithdrawal =>
          AppColors.savings,
      };

  /// Fees apply when money leaves an account through a provider.
  bool get _hasFee => switch (_type) {
        TransactionType.expense ||
        TransactionType.transfer ||
        TransactionType.savingsContribution ||
        TransactionType.debtRepayment =>
          true,
        _ => false,
      };

  String get _accountLabel => switch (_type) {
        TransactionType.income => 'Received into',
        TransactionType.refund => 'Refunded to',
        TransactionType.savingsWithdrawal => 'Moved to',
        TransactionType.transfer => 'From account',
        _ => 'Paid from',
      };

  void _selectType(TransactionType type) => setState(() {
        _type = type;
        _categoryId = DefaultCategories.hasFixedCategory(type)
            ? DefaultCategories.fixedCategoryFor(type)
            : null; // categories differ per type
        _showCategoryError = false;
        if (type != TransactionType.transfer) _toAccount = null;
      });

  /// Turns the form into a cash withdrawal (M-Pesa → Cash) or a cash deposit
  /// (Cash → M-Pesa): a real transfer with both accounts set, so it counts
  /// as neither spending nor income. Amount, fee, date and note are kept; an
  /// empty description is filled in. Editing an older entry this way updates
  /// that same entry rather than adding a new one.
  void _recordCashMove({required bool withdrawal}) {
    _selectType(TransactionType.transfer);
    setState(() {
      _account = withdrawal ? Account.mpesa : Account.cash;
      _toAccount = withdrawal ? Account.cash : Account.mpesa;
    });
    if (_descriptionController.text.trim().isEmpty) {
      _descriptionController.text =
          withdrawal ? 'Cash withdrawal' : 'Cash deposit';
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked == null) return;
    // Keep the original time of day so ordering within a day is stable.
    setState(() => _date = DateTime(
          picked.year,
          picked.month,
          picked.day,
          _date.hour,
          _date.minute,
          _date.second,
        ));
  }

  static double? _optionalNumber(TextEditingController c) {
    final text = c.text.trim();
    return text.isEmpty ? null : double.parse(text);
  }

  void _save() {
    final formValid = _formKey.currentState!.validate();
    setState(() => _showCategoryError = _categoryId == null);
    if (!formValid || _categoryId == null) return;

    final note = _noteController.text.trim();
    final initial = widget.initial;
    final transaction = TransactionModel(
      id: initial?.id ?? '', // Firestore assigns ids to new ones
      description: _descriptionController.text.trim(),
      amount: double.parse(_amountController.text.trim()),
      type: _type,
      categoryId: _categoryId!,
      date: _date,
      note: note.isEmpty ? null : note,
      // Keep where it came from when editing a detected transaction.
      source: initial?.source ?? TransactionSource.manual,
      reference: initial?.reference,
      smsText: initial?.smsText,
      account: _account,
      toAccount: _type == TransactionType.transfer ? _toAccount : null,
      fee: _hasFee ? _optionalNumber(_feeController) : null,
      interest: _type == TransactionType.debtRepayment
          ? _optionalNumber(_interestController)
          : null,
      refundOf: _type == TransactionType.refund ? initial?.refundOf : null,
    );
    Navigator.of(context).pop(TransactionSaved(transaction));
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete transaction?'),
        content: const Text("This can't be undone."),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.expense),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      Navigator.of(context).pop(TransactionDeleted(widget.initial!));
    }
  }

  /// For an entry still saved with an old cash category: true for a cash
  /// withdrawal, false for a deposit; otherwise null.
  bool? get _oldCashCategory => switch ((_type, _categoryId)) {
        (TransactionType.expense, 'cash_withdrawal') => true,
        (TransactionType.income, 'cash_deposit') => false,
        _ => null,
      };

  /// The types besides expense and income, offered as chips.
  static const _otherTypes = [
    TransactionType.transfer,
    TransactionType.savingsContribution,
    TransactionType.savingsWithdrawal,
    TransactionType.refund,
    TransactionType.debtRepayment,
  ];

  /// One line explaining how the chosen type affects the totals.
  String? get _typeHelp => switch (_type) {
        TransactionType.transfer => 'Moving your own money, e.g. withdrawing '
            'cash. Not income or spending.',
        TransactionType.savingsContribution =>
          'Money set aside. Not counted as spending.',
        TransactionType.savingsWithdrawal =>
          'Money taken out of savings. Not counted as income.',
        TransactionType.refund =>
          'Money returned for a purchase. Reduces spending in its category.',
        TransactionType.debtRepayment =>
          'Paying back a loan. Only the interest counts as spending.',
        _ => null,
      };

  String? _validateInterest(String? value) {
    final error = Validators.optionalAmount(value);
    if (error != null) return error;
    final interest = double.tryParse(value?.trim() ?? '');
    final amount = double.tryParse(_amountController.text.trim());
    if (interest != null && amount != null && interest > amount) {
      return "Can't be more than the amount repaid";
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final categories = DefaultCategories.forType(_type,
        keep: widget.initial?.categoryId);
    final fixedCategory = DefaultCategories.hasFixedCategory(_type);
    // "Not set" is offered only for an older entry that has no account.
    final accountChoices = <Account?>[
      if (_isEditing && widget.initial!.effectiveAccount == null) null,
      ...Account.spendable,
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit transaction' : 'Add transaction'),
        actions: [
          if (_isEditing)
            IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: _confirmDelete,
            ),
        ],
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          // Not a ListView: that disposes fields scrolled far off screen, and
          // Form.validate() would then skip them (e.g. an invalid amount at
          // the top while the user taps Save at the bottom).
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.initial case final t? when t.isDetected) ...[
                  _DetectedInfo(transaction: t),
                  const SizedBox(height: 16),
                ],
                if (_oldCashCategory case final withdrawal?) ...[
                  _ConvertCashCard(
                    withdrawal: withdrawal,
                    onConvert: () => _recordCashMove(withdrawal: withdrawal),
                  ),
                  const SizedBox(height: 16),
                ],
                SegmentedButton<TransactionType>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: TransactionType.expense,
                      label: Text('Expense'),
                      icon: Icon(Icons.arrow_upward_rounded),
                    ),
                    ButtonSegment(
                      value: TransactionType.income,
                      label: Text('Income'),
                      icon: Icon(Icons.arrow_downward_rounded),
                    ),
                  ],
                  // Nothing highlighted while one of the other types is chosen.
                  emptySelectionAllowed: true,
                  selected: {
                    if (_type == TransactionType.expense ||
                        _type == TransactionType.income)
                      _type,
                  },
                  onSelectionChanged: (selection) {
                    if (selection.isNotEmpty) _selectType(selection.first);
                  },
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final type in _otherTypes)
                      ChoiceChip(
                        label: Text(type.label),
                        selected: _type == type,
                        onSelected: (_) => _selectType(type),
                      ),
                    // Cash at an agent is a transfer, not spending or income.
                    if (_type == TransactionType.expense ||
                        _type == TransactionType.income)
                      ActionChip(
                        avatar: const Icon(Icons.swap_horiz_rounded, size: 18),
                        label: Text(_type == TransactionType.expense
                            ? 'Cash withdrawal → Transfer'
                            : 'Cash deposit → Transfer'),
                        onPressed: () => _recordCashMove(
                            withdrawal: _type == TransactionType.expense),
                      ),
                  ],
                ),
                if (_typeHelp case final help?) ...[
                  const SizedBox(height: 8),
                  Text(
                    help,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                TextFormField(
                  controller: _amountController,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    color: _accent,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Amount',
                    prefixText: '${Formatters.currencySymbol} ',
                  ),
                  validator: Validators.amount,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _descriptionController,
                  textCapitalization: TextCapitalization.sentences,
                  maxLength: 100,
                  decoration: const InputDecoration(
                    labelText: 'Description',
                    hintText: 'e.g. Groceries',
                    counterText: '',
                  ),
                  validator: (value) => Validators.requiredText(
                    value,
                    emptyMessage: 'Enter a description',
                    max: 100, // same limit as the security rules
                  ),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<Account?>(
                  key: ValueKey('account-$_type'),
                  initialValue: _account,
                  decoration: InputDecoration(labelText: _accountLabel),
                  items: [
                    for (final a in accountChoices)
                      DropdownMenuItem(
                        value: a,
                        child: Text(a?.label ?? 'Not set'),
                      ),
                  ],
                  onChanged: (a) => setState(() => _account = a),
                  validator: (a) => _type == TransactionType.transfer && a == null
                      ? 'Choose where the money came from'
                      : null,
                ),
                if (_type == TransactionType.transfer) ...[
                  const SizedBox(height: 16),
                  DropdownButtonFormField<Account>(
                    key: const ValueKey('toAccount'),
                    initialValue: _toAccount,
                    decoration: const InputDecoration(labelText: 'To account'),
                    items: [
                      for (final a in Account.spendable)
                        DropdownMenuItem(value: a, child: Text(a.label)),
                    ],
                    onChanged: (a) => setState(() => _toAccount = a),
                    validator: (a) {
                      if (a == null) return 'Choose where the money went';
                      if (a == _account) return 'Pick a different account';
                      return null;
                    },
                  ),
                ],
                if (_hasFee) ...[
                  const SizedBox(height: 16),
                  TextFormField(
                    key: const ValueKey('fee'),
                    controller: _feeController,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Transaction cost (optional)',
                      helperText: 'e.g. the M-Pesa charge. Counted as spending.',
                      prefixText: '${Formatters.currencySymbol} ',
                    ),
                    validator: Validators.optionalAmount,
                  ),
                ],
                if (_type == TransactionType.debtRepayment) ...[
                  const SizedBox(height: 16),
                  TextFormField(
                    key: const ValueKey('interest'),
                    controller: _interestController,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Interest or charges included (optional)',
                      helperText: 'Only this part counts as spending. Leave it '
                          "empty if you don't know it.",
                      prefixText: '${Formatters.currencySymbol} ',
                    ),
                    validator: _validateInterest,
                  ),
                ],
                if (!fixedCategory) ...[
                  const SizedBox(height: 20),
                  Text(
                    _type == TransactionType.refund
                        ? 'Category of the purchase refunded'
                        : 'Category',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final category in categories)
                        ChoiceChip(
                          avatar: Icon(category.icon, size: 18),
                          label: Text(category.name),
                          selected: _categoryId == category.id,
                          onSelected: (_) => setState(() {
                            _categoryId = category.id;
                            _showCategoryError = false;
                          }),
                        ),
                    ],
                  ),
                  if (_showCategoryError)
                    Padding(
                      padding: const EdgeInsets.only(top: 6, left: 4),
                      child: Text(
                        'Choose a category',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
                const SizedBox(height: 20),
                InkWell(
                  onTap: _pickDate,
                  borderRadius: BorderRadius.circular(12),
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Date',
                      suffixIcon: Icon(Icons.calendar_today_rounded),
                    ),
                    child: Text(Formatters.shortDate(_date)),
                  ),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _noteController,
                  maxLines: 2,
                  maxLength: 500,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Note (optional)',
                    counterText: '',
                  ),
                  validator: (value) => Validators.optionalText(value, max: 500),
                ),
                const SizedBox(height: 28),
                FilledButton(
                  onPressed: _save,
                  child: Text(_isEditing ? 'Save changes' : 'Save transaction'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// For a transaction detected from an SMS: where it came from, its code,
/// and (collapsed by default) the original message with numbers masked.
class _DetectedInfo extends StatelessWidget {
  const _DetectedInfo({required this.transaction});

  final TransactionModel transaction;

  @override
  Widget build(BuildContext context) {
    final t = transaction;
    final sms = t.smsText;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Theme(
        // No divider lines when the tile expands.
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: const Icon(Icons.sms_outlined, color: AppColors.primary),
          title: Text('Detected from ${t.source.label} SMS'),
          subtitle: Text(
            [
              if (t.reference != null) 'Code ${t.reference}',
              'Check the category and details',
            ].join(' · '),
            style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Original message (phone and account numbers masked)',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 6),
            SelectableText(
              sms ?? 'Not available.',
              style: const TextStyle(color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when editing an entry saved before cash withdrawals and deposits
/// became transfers, offering to convert it in place.
class _ConvertCashCard extends StatelessWidget {
  const _ConvertCashCard({required this.withdrawal, required this.onConvert});

  final bool withdrawal;
  final VoidCallback onConvert;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      color: AppColors.warning.withValues(alpha: 0.10),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              withdrawal
                  ? 'Saved as an expense'
                  : 'Saved as income',
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              withdrawal
                  ? 'A cash withdrawal moves your money from M-Pesa to Cash. '
                      'As a transfer, only its fee counts as spending.'
                  : 'A cash deposit moves your money from Cash to M-Pesa. '
                      'As a transfer, it is not counted as income.',
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: onConvert,
              icon: const Icon(Icons.swap_horiz_rounded),
              label: const Text('Convert to transfer'),
            ),
          ],
        ),
      ),
    );
  }
}
