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

/// Full-screen form for adding an income or expense, or editing one.
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

  late TransactionType _type;
  String? _categoryId;
  bool _showCategoryError = false;
  late DateTime _date;

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
    _type = initial?.type ?? TransactionType.expense;
    _categoryId = initial?.categoryId;
    _date = initial?.date ?? DateTime.now();
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
    super.dispose();
  }

  Color get _accent =>
      _type == TransactionType.expense ? AppColors.expense : AppColors.income;

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

  void _save() {
    final formValid = _formKey.currentState!.validate();
    setState(() => _showCategoryError = _categoryId == null);
    if (!formValid || _categoryId == null) return;

    final note = _noteController.text.trim();
    final transaction = TransactionModel(
      id: widget.initial?.id ?? '', // Firestore assigns ids to new ones
      description: _descriptionController.text.trim(),
      amount: double.parse(_amountController.text.trim()),
      type: _type,
      categoryId: _categoryId!,
      date: _date,
      note: note.isEmpty ? null : note,
      // Keep where it came from when editing a detected transaction.
      source: widget.initial?.source ?? TransactionSource.manual,
      reference: widget.initial?.reference,
      smsText: widget.initial?.smsText,
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

  @override
  Widget build(BuildContext context) {
    final categories = DefaultCategories.forType(_type);

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
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              if (widget.initial case final t? when t.isDetected) ...[
                _DetectedInfo(transaction: t),
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
                selected: {_type},
                onSelectionChanged: (selection) => setState(() {
                  _type = selection.first;
                  _categoryId = null; // categories differ per type
                }),
              ),
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
              const SizedBox(height: 20),
              const Text(
                'Category',
                style: TextStyle(
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
