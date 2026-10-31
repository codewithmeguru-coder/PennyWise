import 'package:flutter/material.dart';

import '../privacy/savings_privacy.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';

/// The green hero card at the top of the dashboard: money available to
/// spend now, and money in savings (kept separate). The month's income and
/// spending are in the monthly overview below it.
class BalanceCard extends StatelessWidget {
  const BalanceCard({
    super.key,
    required this.balance,
    this.savings = 0,
    this.note,
    this.noteLabel = 'Estimated',
  });

  /// How far [balance] can be trusted, e.g. "2 accounts have no starting
  /// balance"; null when it is fully checked. Shown as a small [noteLabel]
  /// tag beside the title; tapping it shows the full note.
  final String? note;
  final String noteLabel;

  /// Money available to spend (every account except savings).
  final double balance;

  /// Money in savings. The row is hidden while it is zero.
  final double savings;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [context.colors.heroStart, context.colors.primaryDark],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Flexible(
                child: Text(
                  'Available balance',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
              ),
              if (note != null) ...[
                const SizedBox(width: 8),
                Flexible(child: Tooltip(
                  message: note!,
                  triggerMode: TooltipTriggerMode.tap,
                  showDuration: const Duration(seconds: 6),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.info_outline_rounded,
                            size: 12, color: Colors.white),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(noteLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 11)),
                        ),
                      ],
                    ),
                  ),
                )),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Text(
            Formatters.currency(balance),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 30,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (savings != 0) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                const Icon(Icons.savings_rounded,
                    size: 16, color: Colors.white70),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    'Savings ${SavingsPrivacy.amount(context, savings)}',
                    key: const Key('balance-savings'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
                if (SavingsPrivacy.maybeOf(context) case final p?
                    when p.enabled)
                  IconButton(
                    key: const Key('savings-eye'),
                    tooltip: p.hidden ? 'Show savings' : 'Hide savings',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      p.hidden
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      size: 18,
                      color: Colors.white70,
                    ),
                    onPressed: p.toggle,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
