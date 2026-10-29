import 'package:flutter/foundation.dart';

/// The month Home and Budgets show, shared so both stay on the same one.
///
/// Always the first day of a month (local time), never before [first] and
/// never after the current month: future months can't be chosen. Lives only
/// while the app runs; it starts on the current month.
class MonthSelection extends ValueNotifier<DateTime> {
  MonthSelection({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now,
      super(_monthOf((clock ?? DateTime.now)()));

  /// Earliest month the transaction form allows dates for.
  static final first = DateTime(2020, 1);

  final DateTime Function() _clock;

  static DateTime _monthOf(DateTime d) => DateTime(d.year, d.month);

  /// The latest month that can be chosen.
  DateTime get current => _monthOf(_clock());

  bool get canGoBack => value.isAfter(first);
  bool get canGoForward => value.isBefore(current);

  /// Sets the month containing [month], kept between [first] and [current].
  @override
  set value(DateTime month) {
    var m = _monthOf(month);
    if (m.isBefore(first)) m = first;
    if (m.isAfter(current)) m = current;
    super.value = m;
  }

  void previous() => value = DateTime(value.year, value.month - 1);
  void next() => value = DateTime(value.year, value.month + 1);
}
