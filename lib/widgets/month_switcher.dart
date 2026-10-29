import 'package:flutter/material.dart';

import '../models/month_selection.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';

/// "‹ October 2026 ›": moves a shared [MonthSelection]. The arrows are
/// disabled at the first month and at the current month.
class MonthSwitcher extends StatelessWidget {
  const MonthSwitcher({
    super.key,
    required this.selection,
    this.padding = const EdgeInsets.fromLTRB(8, 0, 8, 8),
  });

  final MonthSelection selection;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: selection,
      builder: (context, _) => Padding(
        padding: padding,
        child: Row(
          children: [
            IconButton(
              tooltip: 'Previous month',
              onPressed: selection.canGoBack ? selection.previous : null,
              icon: const Icon(Icons.chevron_left_rounded),
            ),
            Expanded(
              child: Text(
                Formatters.monthYear(selection.value),
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
              onPressed: selection.canGoForward ? selection.next : null,
              icon: const Icon(Icons.chevron_right_rounded),
            ),
          ],
        ),
      ),
    );
  }
}
