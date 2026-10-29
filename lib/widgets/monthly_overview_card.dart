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
import '../theme/app_theme.dart';
import '../utils/formatters.dart';
import 'charts/category_donut.dart';
import 'month_switcher.dart';

/// Home's monthly overview for the shared [month]: income, spending and
/// net, the budget (or a way to set one), and spending by category.
///
/// Every figure is [TransactionStore.summaryFor], the same calculation as
/// Budgets, over the user's saved transactions and that month's budget.
class MonthlyOverviewCard extends StatefulWidget {
  const MonthlyOverviewCard({
    super.key,
    required this.store,
    required this.budgetRepository,
    required this.month,
    this.onOpenBudgets,
    this.categoryBudgets,
    this.onOpenTrends,
  });

  /// Under the figures: fees are in Expenses; moves between the user's own
  /// money aren't.
  static const expensesCaption =
      'Includes fees. Transfers, savings and loan repayments aren\'t counted.';

  final TransactionStore store;
  final BudgetRepository budgetRepository;
  final MonthSelection month;

  /// Opens the Budgets tab (same month), e.g. to set a budget.
  final VoidCallback? onOpenBudgets;

  /// Opens month-by-month Trends (ending at the same month).
  final VoidCallback? onOpenTrends;

  /// Per-category limits: categories over or near theirs are mentioned.
  final CategoryBudgetRepository? categoryBudgets;

  @override
  State<MonthlyOverviewCard> createState() => _MonthlyOverviewCardState();
}

class _MonthlyOverviewCardState extends State<MonthlyOverviewCard> {
  late DateTime _shown = widget.month.value;
  late Stream<BudgetModel?> _budget = widget.budgetRepository.watchMonth(
    _shown,
  );
  late Stream<Map<String, double>>? _limits = widget.categoryBudgets
      ?.watchMonth(_shown);

  @override
  void initState() {
    super.initState();
    widget.month.addListener(_monthChanged);
  }

  @override
  void dispose() {
    widget.month.removeListener(_monthChanged);
    super.dispose();
  }

  void _monthChanged() {
    if (widget.month.value == _shown) return;
    setState(() {
      _shown = widget.month.value;
      _budget = widget.budgetRepository.watchMonth(_shown);
      _limits = widget.categoryBudgets?.watchMonth(_shown);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Monthly overview',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                if (widget.onOpenTrends != null)
                  TextButton(
                    onPressed: widget.onOpenTrends,
                    child: const Text('Trends'),
                  ),
                if (widget.onOpenBudgets != null)
                  TextButton(
                    onPressed: widget.onOpenBudgets,
                    child: const Text('Budgets'),
                  ),
              ],
            ),
            MonthSwitcher(
              selection: widget.month,
              padding: const EdgeInsets.only(bottom: 8),
            ),
            ListenableBuilder(
              listenable: widget.store,
              builder: (context, _) => StreamBuilder<BudgetModel?>(
                // A new key per month, so one month's budget never shows
                // under another while the next one loads.
                key: ValueKey(_shown),
                stream: _budget,
                builder: (context, budget) =>
                    StreamBuilder<Map<String, double>>(
                      key: ValueKey('limits $_shown'),
                      stream: _limits,
                      builder: (context, limits) =>
                          _body(context, budget, limits.data ?? const {}),
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// "Food over its limit", "2 categories near their limit"; null when
  /// every category with a limit is on track.
  static String? _limitsLine(CategoryBudgetSummary cats) {
    String one(BudgetStatus status) => DefaultCategories.byId(
      cats.rows.firstWhere((r) => r.status == status).categoryId,
    ).name;
    final over = cats.overCount, near = cats.nearCount;
    final parts = [
      if (over == 1) '${one(BudgetStatus.over)} over its limit',
      if (over > 1) '$over categories over their limit',
      if (near == 1) '${one(BudgetStatus.nearLimit)} near its limit',
      if (near > 1) '$near categories near their limit',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// Limits that couldn't be loaded are left out (Budgets says why).
  Widget _body(
    BuildContext context,
    AsyncSnapshot<BudgetModel?> budget,
    Map<String, double> limits,
  ) {
    final store = widget.store;
    if (store.error != null) {
      return _Notice(
        icon: Icons.cloud_off_rounded,
        text: 'Couldn\'t load transactions. ${store.error!}',
        action: TextButton(onPressed: store.retry, child: const Text('Retry')),
      );
    }
    if (store.isLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final summary = store.summaryFor(_shown, budget: budget.data?.limit);
    final monthName = Formatters.monthYear(_shown);
    final cats = CategoryBudgetSummary.of(summary, limits);
    final limitsLine = _limitsLine(cats);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _Figure(
                label: 'Income',
                amount: summary.income,
                color: AppColors.income,
              ),
            ),
            Expanded(
              child: _Figure(
                label: 'Expenses',
                amount: summary.expenses,
                color: AppColors.expense,
              ),
            ),
            Expanded(
              child: _Figure(label: 'Net', amount: summary.net, signed: true),
            ),
          ],
        ),
        const SizedBox(height: 4),
        // What "Expenses" means, by the Ledger's rules.
        const Text(
          MonthlyOverviewCard.expensesCaption,
          key: Key('overview-expenses-caption'),
          style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 12),
        if (budget.hasError)
          _Notice(
            icon: Icons.cloud_off_rounded,
            text: DataException.from(budget.error!).message,
          )
        else if (budget.connectionState == ConnectionState.waiting)
          const _Notice(
            icon: Icons.hourglass_empty_rounded,
            text: 'Loading budget…',
          )
        else if (summary.hasBudget)
          _BudgetLine(summary: summary)
        else
          _Notice(
            icon: Icons.account_balance_wallet_outlined,
            text: 'No budget for $monthName',
            action: widget.onOpenBudgets == null
                ? null
                : TextButton(
                    onPressed: widget.onOpenBudgets,
                    child: const Text('Set budget'),
                  ),
          ),
        if (limitsLine != null) ...[
          const SizedBox(height: 8),
          InkWell(
            onTap: widget.onOpenBudgets,
            child: _Notice(
              icon: Icons.warning_amber_rounded,
              color: cats.overCount > 0 ? AppColors.expense : AppColors.warning,
              text: limitsLine,
            ),
          ),
        ],
        const SizedBox(height: 16),
        if (summary.byCategory.isNotEmpty)
          CategoryDonut(
            categories: summary.byCategory,
            onTap: widget.onOpenBudgets,
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              summary.transactionCount == 0
                  ? 'No transactions in $monthName'
                  : 'No spending in $monthName',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
          ),
      ],
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({
    required this.label,
    required this.amount,
    this.color,
    this.signed = false,
  });

  final String label;
  final double amount;
  final Color? color;

  /// A leading "+" for positive amounts (negatives always show "-").
  final bool signed;

  @override
  Widget build(BuildContext context) {
    final text = Formatters.currency(amount);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            signed && amount > 0 ? '+$text' : text,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: color ?? AppColors.textPrimary,
            ),
          ),
        ),
      ],
    );
  }
}

/// "KSh 2,000.00 left of KSh 10,000.00" with a meter in the status colour.
class _BudgetLine extends StatelessWidget {
  const _BudgetLine({required this.summary});

  final MonthlySummary summary;

  @override
  Widget build(BuildContext context) {
    final remaining = summary.remaining!;
    final color = switch (summary.status!) {
      BudgetStatus.onTrack => AppColors.primary,
      BudgetStatus.nearLimit => AppColors.warning,
      BudgetStatus.over => AppColors.expense,
    };
    final percentUsed = (summary.usedFraction! * 100).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          remaining < 0
              ? '${Formatters.currency(-remaining)} over budget · '
                    '$percentUsed% used'
              : '${Formatters.currency(remaining)} left of '
                    '${Formatters.currency(summary.budget!)} · '
                    '$percentUsed% used',
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: summary.usedFraction!.clamp(0.0, 1.0),
            minHeight: 8,
            color: color,
            backgroundColor: color.withValues(alpha: 0.15),
            semanticsLabel: '$percentUsed% of budget used',
          ),
        ),
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.text,
    this.action,
    this.color = AppColors.textSecondary,
  });

  final IconData icon;
  final String text;
  final Widget? action;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: TextStyle(color: color)),
        ),
        ?action,
      ],
    );
  }
}
