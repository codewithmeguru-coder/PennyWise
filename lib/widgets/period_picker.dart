import 'package:flutter/material.dart';

import '../models/month_selection.dart';
import '../models/spend_period.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';

/// Jump straight to a day or week instead of tapping the arrows: Android's
/// calendar, where any day picks its Monday-to-Sunday week. (Months use
/// [showMonthPicker].) Nothing before [MonthSelection.first] or after today
/// can be picked. Null when cancelled.
Future<PeriodRange?> pickPeriod(
  BuildContext context,
  PeriodRange current, {
  required DateTime now,
}) async {
  final today = DateTime(now.year, now.month, now.day);
  final first = MonthSelection.first;
  final day = await showDatePicker(
    context: context,
    initialDate: _clamp(current.start, first, today),
    firstDate: first,
    lastDate: today,
    helpText: current.period == SpendPeriod.day
        ? 'Go to day'
        : 'Go to week (pick any day in it)',
  );
  return day == null ? null : PeriodRange.containing(current.period, day);
}

DateTime _clamp(DateTime d, DateTime lo, DateTime hi) =>
    d.isBefore(lo) ? lo : (d.isAfter(hi) ? hi : d);

/// A year with ‹ › arrows over a grid of its 12 months. Returns the first
/// day of the chosen month, or null when cancelled. Months before [first]'s
/// month or after [last]'s month are disabled.
Future<DateTime?> showMonthPicker(
  BuildContext context, {
  required DateTime initial,
  required DateTime first,
  required DateTime last,
}) => showDialog<DateTime>(
  context: context,
  builder: (_) => _MonthPickerDialog(
    initial: DateTime(initial.year, initial.month),
    first: DateTime(first.year, first.month),
    last: DateTime(last.year, last.month),
  ),
);

class _MonthPickerDialog extends StatefulWidget {
  const _MonthPickerDialog({
    required this.initial,
    required this.first,
    required this.last,
  });

  final DateTime initial, first, last;

  @override
  State<_MonthPickerDialog> createState() => _MonthPickerDialogState();
}

class _MonthPickerDialogState extends State<_MonthPickerDialog> {
  late int _year = widget.initial.year;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Go to month'),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: 'Previous year',
                  onPressed: _year > widget.first.year
                      ? () => setState(() => _year--)
                      : null,
                  icon: const Icon(Icons.chevron_left_rounded),
                ),
                Expanded(
                  child: Text(
                    '$_year',
                    key: const Key('month-picker-year'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: context.colors.textPrimary,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Next year',
                  onPressed: _year < widget.last.year
                      ? () => setState(() => _year++)
                      : null,
                  icon: const Icon(Icons.chevron_right_rounded),
                ),
              ],
            ),
            const SizedBox(height: 8),
            GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 2,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              children: [
                for (var m = 1; m <= 12; m++) _month(context, m),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _month(BuildContext context, int m) {
    final month = DateTime(_year, m);
    final enabled =
        !month.isBefore(widget.first) && !month.isAfter(widget.last);
    final selected = month == widget.initial;
    final label = Text(
      Formatters.shortMonth(m),
      key: Key('month-picker-$m'),
    );
    void choose() => Navigator.pop(context, month);
    return selected
        ? FilledButton(onPressed: choose, child: label)
        : OutlinedButton(onPressed: enabled ? choose : null, child: label);
  }
}

/// A switcher's label ("October 2026") that opens a picker when tapped,
/// with a small calendar icon so it reads as tappable.
class PickerLabel extends StatelessWidget {
  const PickerLabel({
    super.key,
    required this.child,
    required this.onTap,
    required this.tooltip,
  });

  final Widget child;
  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(child: child),
            const SizedBox(width: 6),
            Icon(
              Icons.calendar_month_rounded,
              size: 18,
              color: context.colors.textSecondary,
            ),
          ],
        ),
      ),
    ),
  );
}
