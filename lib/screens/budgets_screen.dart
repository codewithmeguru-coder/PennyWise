import 'package:flutter/material.dart';

import '../data/budget_repository.dart';
import '../data/data_exception.dart';
import '../data/transaction_store.dart';
import '../models/budget_model.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';
import '../utils/validators.dart';
import '../widgets/budget_card.dart';
import '../widgets/category_spend_chart.dart';
import '../widgets/empty_state.dart';
import '../widgets/section_header.dart';

/// Budgets tab: pick a month, set its budget, and see income, expenses,
/// what's left, and spending by category — all for that month only.
class BudgetsScreen extends StatefulWidget {
  const BudgetsScreen({
    super.key,
    required this.store,
    required this.budgetRepository,
    this.onOpenMenu,
  });

  final TransactionStore store;
  final BudgetRepository budgetRepository;

  /// Opens the side menu. When null, no ☰ button is shown.
  final VoidCallback? onOpenMenu;

  @override
  State<BudgetsScreen> createState() => _BudgetsScreenState();
}

class _BudgetsScreenState extends State<BudgetsScreen> {
  /// Earliest month the transaction form allows dates for.
  static final _firstMonth = DateTime(2020, 1);

  /// Always the first day of the selected month.
  DateTime _month = _currentMonth();
  late Stream<BudgetModel?> _budget = widget.budgetRepository.watchMonth(_month);

  static DateTime _currentMonth() {
    final now = DateTime.now();
    return DateTime(now.year, now.month);
  }

  bool get _canGoBack => _month.isAfter(_firstMonth);
  bool get _canGoForward => _month.isBefore(_currentMonth());

  void _changeMonth(int delta) {
    setState(() {
      _month = DateTime(_month.year, _month.month + delta);
      _budget = widget.budgetRepository.watchMonth(_month);
    });
  }

  Future<void> _editBudget(double? current) async {
    final result = await showDialog<_BudgetDialogResult>(
      context: context,
      builder: (_) => _BudgetDialog(month: _month, current: current),
    );
    if (result == null || !mounted) return;

    final month = _month;
    final repository = widget.budgetRepository;
    // The screen updates straight away from Firestore's local cache; only a
    // rejected write needs a message.
    try {
      final limit = result.limit;
      if (limit == null) {
        await repository.delete(month);
      } else {
        await repository.save(BudgetModel(month: month, limit: limit));
      }
    } on DataException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message), behavior: SnackBarBehavior.floating),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Budgets'),
        leading: widget.onOpenMenu == null
            ? null
            : IconButton(
                tooltip: 'Menu',
                icon: const Icon(Icons.menu_rounded),
                onPressed: widget.onOpenMenu,
              ),
      ),
      body: Column(
        children: [
          _MonthSwitcher(
            month: _month,
            onPrevious: _canGoBack ? () => _changeMonth(-1) : null,
            onNext: _canGoForward ? () => _changeMonth(1) : null,
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: widget.store,
              builder: (context, _) => StreamBuilder<BudgetModel?>(
                // A new key per month, so one month's budget never shows
                // while the next month's is loading.
                key: ValueKey(BudgetModel.idFor(_month)),
                stream: _budget,
                builder: _buildBody,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, AsyncSnapshot<BudgetModel?> budget) {
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
    if (store.isLoading ||
        budget.connectionState == ConnectionState.waiting) {
      return const Center(child: CircularProgressIndicator());
    }

    final summary = store.summaryFor(_month, budget: budget.data?.limit);
    final monthName = Formatters.monthYear(_month);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        BudgetCard(
          summary: summary,
          error: budget.hasError ? DataException.from(budget.error!).message : null,
          onEdit: () => _editBudget(summary.budget),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _StatTile(label: 'Income', amount: summary.income),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _StatTile(label: 'Expenses', amount: summary.expenses),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _StatTile(label: 'Net', amount: summary.net, signed: true),
            ),
          ],
        ),
        const SizedBox(height: 20),
        const SectionHeader(title: 'Spending by category'),
        if (summary.byCategory.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: EmptyState(
              icon: Icons.pie_chart_outline_rounded,
              title: summary.transactionCount == 0
                  ? 'No transactions in $monthName'
                  : 'No spending in $monthName',
              message: 'Expenses you add for this month will appear here.',
            ),
          )
        else
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: CategorySpendChart(categories: summary.byCategory),
            ),
          ),
      ],
    );
  }
}

class _MonthSwitcher extends StatelessWidget {
  const _MonthSwitcher({
    required this.month,
    required this.onPrevious,
    required this.onNext,
  });

  final DateTime month;

  /// Null disables the button (at the first / current month).
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Previous month',
            onPressed: onPrevious,
            icon: const Icon(Icons.chevron_left_rounded),
          ),
          Expanded(
            child: Text(
              Formatters.monthYear(month),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Next month',
            onPressed: onNext,
            icon: const Icon(Icons.chevron_right_rounded),
          ),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.label,
    required this.amount,
    this.signed = false,
  });

  final String label;
  final double amount;

  /// Show a leading "+" for positive amounts (negatives always show "-").
  final bool signed;

  @override
  Widget build(BuildContext context) {
    final text = Formatters.currency(amount);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                signed && amount > 0 ? '+$text' : text,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// [limit] null means "remove this month's budget".
class _BudgetDialogResult {
  const _BudgetDialogResult(this.limit);

  final double? limit;
}

class _BudgetDialog extends StatefulWidget {
  const _BudgetDialog({required this.month, required this.current});

  final DateTime month;
  final double? current;

  @override
  State<_BudgetDialog> createState() => _BudgetDialogState();
}

class _BudgetDialogState extends State<_BudgetDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _controller = TextEditingController(
    text: widget.current == null ? '' : _format(widget.current!),
  );

  /// 50000.0 -> "50000", 12.5 -> "12.50"
  static String _format(double amount) => amount == amount.roundToDouble()
      ? amount.toStringAsFixed(0)
      : amount.toStringAsFixed(2);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context)
        .pop(_BudgetDialogResult(double.parse(_controller.text.trim())));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Budget for ${Formatters.monthYear(widget.month)}'),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Monthly limit',
            prefixText: '${Formatters.currencySymbol} ',
          ),
          validator: Validators.amount,
          onFieldSubmitted: (_) => _save(),
        ),
      ),
      actions: [
        if (widget.current != null)
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(const _BudgetDialogResult(null)),
            style: TextButton.styleFrom(foregroundColor: AppColors.expense),
            child: const Text('Remove'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
