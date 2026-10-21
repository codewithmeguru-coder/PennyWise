import 'package:flutter/material.dart';

import '../models/monthly_summary.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';

/// The month's budget: remaining amount, a meter of how much is used, and a
/// status (on track / near limit / over). With no budget set, it invites the
/// user to set one.
class BudgetCard extends StatelessWidget {
  const BudgetCard({
    super.key,
    required this.summary,
    required this.onEdit,
    this.error,
  });

  final MonthlySummary summary;

  /// Opens the set / edit budget dialog.
  final VoidCallback onEdit;

  /// Shown instead of the budget if it couldn't be loaded.
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: error != null
            ? _Message(icon: Icons.cloud_off_rounded, text: error!)
            : summary.hasBudget
                ? _BudgetDetails(summary: summary, onEdit: onEdit)
                : _NoBudget(month: summary.month, onSet: onEdit),
      ),
    );
  }
}

class _NoBudget extends StatelessWidget {
  const _NoBudget({required this.month, required this.onSet});

  final DateTime month;
  final VoidCallback onSet;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'No budget for ${Formatters.monthYear(month)}',
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Set a spending limit to see how much you have left.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: onSet,
          icon: const Icon(Icons.add_rounded),
          label: const Text('Set budget'),
        ),
      ],
    );
  }
}

class _BudgetDetails extends StatelessWidget {
  const _BudgetDetails({required this.summary, required this.onEdit});

  final MonthlySummary summary;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final remaining = summary.remaining!;
    final (color, icon, label) = switch (summary.status!) {
      BudgetStatus.onTrack =>
        (AppColors.primary, Icons.check_circle_rounded, 'On track'),
      BudgetStatus.nearLimit =>
        (AppColors.warning, Icons.warning_amber_rounded, 'Near limit'),
      BudgetStatus.over =>
        (AppColors.expense, Icons.error_rounded, 'Over budget'),
    };
    final percentUsed = (summary.usedFraction! * 100).round();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                remaining < 0 ? 'Over budget by' : 'Remaining',
                style: const TextStyle(color: AppColors.textSecondary),
              ),
            ),
            TextButton.icon(
              onPressed: onEdit,
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Edit budget'),
            ),
          ],
        ),
        Text(
          Formatters.currency(remaining.abs()),
          style: const TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 12),
        // Meter: the fill carries the status colour; the track is a lighter
        // step of the same colour. Shown full when over budget.
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: summary.usedFraction!.clamp(0.0, 1.0),
            minHeight: 10,
            color: color,
            backgroundColor: color.withValues(alpha: 0.15),
            // The meter's own value is capped at 100%, so state the real
            // figure (which can exceed 100%) in the label.
            semanticsLabel: '$percentUsed% of budget used',
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${Formatters.currency(summary.expenses)} of '
                '${Formatters.currency(summary.budget!)} · $percentUsed%',
                textAlign: TextAlign.right,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: AppColors.textSecondary),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(color: AppColors.textSecondary),
          ),
        ),
      ],
    );
  }
}
