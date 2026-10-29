import 'package:flutter/material.dart';

import '../data/budget_repository.dart';
import '../data/category_budget_repository.dart';
import '../data/data_exception.dart';
import '../data/transaction_store.dart';
import '../models/budget_model.dart';
import '../models/category_budget.dart';
import '../models/month_selection.dart';
import '../models/monthly_summary.dart';
import '../models/transaction_category.dart';
import '../models/spending_trend.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';
import '../utils/validators.dart';
import '../widgets/budget_card.dart';
import '../widgets/category_limit_list.dart';
import '../widgets/charts/chart_style.dart';
import '../widgets/charts/spending_vs_budget_chart.dart';
import '../widgets/empty_state.dart';
import '../widgets/month_switcher.dart';
import '../widgets/section_header.dart';

/// Budgets tab: pick a month, set its budget and category limits, and see
/// income, expenses, what's left, and spending by category — all for that
/// month only.
class BudgetsScreen extends StatefulWidget {
  const BudgetsScreen({
    super.key,
    required this.store,
    required this.budgetRepository,
    this.onOpenMenu,
    this.month,
    this.categoryBudgets,
    this.onOpenTrends,
  });

  final TransactionStore store;
  final BudgetRepository budgetRepository;

  /// Per-category limits. Null: categories show spending only.
  final CategoryBudgetRepository? categoryBudgets;

  /// Opens month-by-month Trends; null hides the button.
  final VoidCallback? onOpenTrends;

  /// The month shown, shared with Home. Null: this screen keeps its own.
  final MonthSelection? month;

  /// Opens the side menu. When null, no ☰ button is shown.
  final VoidCallback? onOpenMenu;

  @override
  State<BudgetsScreen> createState() => _BudgetsScreenState();
}

class _BudgetsScreenState extends State<BudgetsScreen> {
  late final MonthSelection _selection = widget.month ?? MonthSelection();

  /// Always the first day of the selected month.
  late DateTime _month = _selection.value;
  late Stream<BudgetModel?> _budget = widget.budgetRepository.watchMonth(_month);
  late Stream<Map<String, double>>? _limits =
      widget.categoryBudgets?.watchMonth(_month);

  @override
  void initState() {
    super.initState();
    _selection.addListener(_monthChanged);
  }

  @override
  void dispose() {
    _selection.removeListener(_monthChanged);
    if (widget.month == null) _selection.dispose();
    super.dispose();
  }

  void _monthChanged() {
    if (_selection.value == _month) return;
    setState(() {
      _month = _selection.value;
      _budget = widget.budgetRepository.watchMonth(_month);
      _limits = widget.categoryBudgets?.watchMonth(_month);
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
        actions: [
          if (widget.onOpenTrends != null)
            TextButton.icon(
              onPressed: widget.onOpenTrends,
              icon: const Icon(Icons.insights_rounded),
              label: const Text('Trends'),
            ),
        ],
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
          MonthSwitcher(selection: _selection),
          Expanded(
            child: ListenableBuilder(
              listenable: widget.store,
              builder: (context, _) => StreamBuilder<BudgetModel?>(
                // A new key per month, so one month's budget never shows
                // while the next month's is loading.
                key: ValueKey(BudgetModel.idFor(_month)),
                stream: _budget,
                builder: (context, budget) =>
                    StreamBuilder<Map<String, double>>(
                  // Same for the category limits.
                  key: ValueKey('limits ${BudgetModel.idFor(_month)}'),
                  stream: _limits,
                  builder: (context, limits) =>
                      _buildBody(context, budget, limits),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Spending in each of the six months up to the selected one, the
  /// selected month in full colour.
  Widget _monthlyTotals(TransactionStore store) {
    final totals = SpendingTrend.monthlyTotals(store.transactions, _month);
    return GroupedBarChart(
      labels: [
        for (final (m, _) in totals) Formatters.monthYear(m).substring(0, 3),
      ],
      series: [
        ChartSeries('Spent', AppColors.expense, [
          for (final (_, spent) in totals) spent,
        ]),
      ],
      highlight: totals.length - 1,
      semanticLabel: [
        for (final (m, spent) in totals)
          '${Formatters.monthYear(m)}: ${Formatters.currency(spent)}',
      ].join(', '),
    );
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );
  }

  /// Sets, changes or removes one category's limit for this month. With
  /// [categoryId] null, the dialog first asks which category.
  Future<void> _editLimit(
      String? categoryId, Map<String, double> current) async {
    final result = await showDialog<_LimitResult>(
      context: context,
      builder: (_) => _CategoryLimitDialog(
        month: _month,
        categoryId: categoryId,
        current: categoryId == null ? null : current[categoryId],
        taken: current.keys.toSet(),
      ),
    );
    if (result == null || !mounted) return;
    final month = _month;
    final repository = widget.categoryBudgets!;
    try {
      final limit = result.limit;
      if (limit == null) {
        await repository.delete(month, result.categoryId);
      } else {
        await repository.save(CategoryBudget(
            month: month, categoryId: result.categoryId, limit: limit));
      }
    } on DataException catch (e) {
      if (mounted) _showMessage(e.message);
    }
  }

  /// "Copy last month's limits": adds last month's limit for each category
  /// that has none this month, after the user confirms. Limits already set
  /// this month are kept as they are; last month is not changed.
  Future<void> _copyLastMonth(Map<String, double> current) async {
    final month = _month;
    final from = DateTime(month.year, month.month - 1);
    final repository = widget.categoryBudgets!;
    final fromName = Formatters.monthYear(from);
    final toName = Formatters.monthYear(month);
    final Map<String, double> previous;
    try {
      previous = await repository.watchMonth(from).first;
    } on DataException catch (e) {
      if (mounted) _showMessage(e.message);
      return;
    }
    if (!mounted) return;
    final add = CategoryBudget.toCopy(previous, current);
    if (previous.isEmpty) {
      _showMessage('$fromName has no category limits to copy.');
      return;
    }
    if (add.isEmpty) {
      _showMessage('Every category with a limit in $fromName already has '
          'one in $toName. Nothing to copy.');
      return;
    }
    final kept = previous.keys.where(current.containsKey).length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Copy $fromName\'s limits?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('This adds ${add.length} category '
                  '${add.length == 1 ? 'limit' : 'limits'} to $toName:'),
              const SizedBox(height: 8),
              for (final e in add.entries)
                Text('• ${DefaultCategories.byId(e.key).name}: '
                    '${Formatters.currency(e.value)}'),
              const SizedBox(height: 8),
              Text([
                if (kept > 0)
                  '$kept ${kept == 1 ? 'category that already has a limit' : 'categories that already have a limit'} '
                      'in $toName ${kept == 1 ? 'keeps its' : 'keep their'} '
                      'current limit.',
                'Nothing else changes: $fromName\'s limits and the overall '
                    'budget stay as they are.',
              ].join(' ')),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Copy'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    var done = 0;
    try {
      for (final e in add.entries) {
        await repository.save(
            CategoryBudget(month: month, categoryId: e.key, limit: e.value));
        done++;
      }
    } on DataException catch (e) {
      if (mounted) {
        _showMessage('Copied $done of ${add.length}. ${e.message}');
      }
      return;
    }
    if (mounted) {
      _showMessage('Copied ${add.length} '
          '${add.length == 1 ? 'limit' : 'limits'} from $fromName');
    }
  }

  /// Spending by category, each against its limit when it has one.
  List<Widget> _categorySection(
    MonthlySummary summary,
    AsyncSnapshot<Map<String, double>> limits,
    String monthName,
  ) {
    final repository = widget.categoryBudgets;
    final loaded = repository != null &&
        !limits.hasError &&
        limits.connectionState != ConnectionState.waiting;
    final cats = CategoryBudgetSummary.of(summary, limits.data ?? const {});
    return [
      if (repository != null)
        Wrap(
          spacing: 4,
          children: [
            TextButton.icon(
              onPressed: loaded ? () => _editLimit(null, cats.limits) : null,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add a limit'),
            ),
            TextButton.icon(
              onPressed: loaded ? () => _copyLastMonth(cats.limits) : null,
              icon: const Icon(Icons.content_copy_rounded, size: 18),
              label: const Text('Copy last month\'s limits'),
            ),
          ],
        ),
      if (limits.hasError)
        _Note(
          icon: Icons.cloud_off_rounded,
          text: 'Couldn\'t load category limits. '
              '${DataException.from(limits.error!).message}',
        ),
      if (cats.exceedsOverall)
        _Note(
          icon: Icons.warning_amber_rounded,
          color: AppColors.warning,
          text: 'Category limits add up to '
              '${Formatters.currency(cats.totalLimits)}, more than the '
              'overall budget of ${Formatters.currency(cats.overallBudget!)}. '
              'Neither is changed.',
        ),
      if (cats.rows.isEmpty)
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
            child: CategoryLimitList(
              rows: cats.rows,
              onEdit: loaded ? (id) => _editLimit(id, cats.limits) : null,
            ),
          ),
        ),
    ];
  }

  Widget _buildBody(
    BuildContext context,
    AsyncSnapshot<BudgetModel?> budget,
    AsyncSnapshot<Map<String, double>> limits,
  ) {
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
        ..._categorySection(summary, limits, monthName),
        const SizedBox(height: 20),
        SectionHeader(
          title: summary.hasBudget
              ? 'Spending vs budget'
              : 'Spending this month',
        ),
        _ChartCard(
          child: SpendingVsBudgetChart(
            cumulative:
                SpendingTrend.cumulativeByDay(store.transactions, _month),
            daysInMonth: DateTime(_month.year, _month.month + 1, 0).day,
            budget: summary.budget,
          ),
        ),
        const SizedBox(height: 20),
        const SectionHeader(title: 'Last 6 months'),
        _ChartCard(child: _monthlyTotals(store)),
      ],
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

/// [limit] null means "remove this category's limit for the month".
class _LimitResult {
  const _LimitResult(this.categoryId, this.limit);

  final String categoryId;
  final double? limit;
}

/// Sets one category's limit for a month. With no [categoryId], it also
/// asks which category (from those without a limit yet).
class _CategoryLimitDialog extends StatefulWidget {
  const _CategoryLimitDialog({
    required this.month,
    required this.categoryId,
    required this.current,
    required this.taken,
  });

  final DateTime month;
  final String? categoryId;
  final double? current;

  /// Categories that already have a limit this month.
  final Set<String> taken;

  @override
  State<_CategoryLimitDialog> createState() => _CategoryLimitDialogState();
}

class _CategoryLimitDialogState extends State<_CategoryLimitDialog> {
  final _formKey = GlobalKey<FormState>();
  late String? _categoryId = widget.categoryId;
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
    Navigator.of(context).pop(
        _LimitResult(_categoryId!, double.parse(_controller.text.trim())));
  }

  @override
  Widget build(BuildContext context) {
    final month = Formatters.monthYear(widget.month);
    final choices = [
      for (final c in CategoryBudget.budgetable)
        if (!widget.taken.contains(c.id)) c,
    ];
    return AlertDialog(
      title: Text(widget.categoryId == null
          ? 'Add a limit for $month'
          : '${DefaultCategories.byId(widget.categoryId!).name} limit for '
              '$month'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.categoryId == null)
              choices.isEmpty
                  ? const Text('Every category already has a limit this '
                      'month.')
                  : DropdownButtonFormField<String>(
                      initialValue: _categoryId,
                      isExpanded: true,
                      decoration:
                          const InputDecoration(labelText: 'Category'),
                      items: [
                        for (final c in choices)
                          DropdownMenuItem(value: c.id, child: Text(c.name)),
                      ],
                      onChanged: (v) => setState(() => _categoryId = v),
                      validator: (v) =>
                          v == null ? 'Choose a category' : null,
                    ),
            TextFormField(
              controller: _controller,
              autofocus: widget.categoryId != null,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Monthly limit',
                prefixText: '${Formatters.currencySymbol} ',
              ),
              validator: Validators.amount,
              onFieldSubmitted: (_) => _save(),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.current != null)
          TextButton(
            onPressed: () => Navigator.of(context)
                .pop(_LimitResult(widget.categoryId!, null)),
            style: TextButton.styleFrom(foregroundColor: AppColors.expense),
            child: const Text('Remove'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        if (widget.categoryId != null || choices.isNotEmpty)
          TextButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

/// A one-line message in the category section (load error, warning).
class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text, this.color});

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.textSecondary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: c),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 13, color: c)),
          ),
        ],
      ),
    );
  }
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 16, 16, 12),
        child: child,
      ),
    );
  }
}
