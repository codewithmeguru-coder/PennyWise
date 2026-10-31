import '../utils/formatters.dart';

/// How much time Home's overview covers.
enum SpendPeriod {
  day('Day', 'Daily overview'),
  week('Week', 'Weekly overview'),
  month('Month', 'Monthly overview');

  const SpendPeriod(this.label, this.title);

  /// On the Day | Week | Month toggle.
  final String label;

  /// The overview card's heading.
  final String title;
}

/// One day, one Monday-to-Sunday week, or one calendar month, in the
/// phone's local time: from [start] (midnight) up to, not including, [end].
///
/// Days are counted with `DateTime(y, m, d + n)`, never by adding hours, so
/// a daylight-saving change can't shift a boundary.
class PeriodRange {
  const PeriodRange._(this.period, this.start, this.end);

  /// The [period] that contains [date].
  factory PeriodRange.containing(SpendPeriod period, DateTime date) {
    final day = DateTime(date.year, date.month, date.day);
    return switch (period) {
      SpendPeriod.day => PeriodRange._(
        period,
        day,
        DateTime(day.year, day.month, day.day + 1),
      ),
      // DateTime.weekday: Monday = 1 ... Sunday = 7.
      SpendPeriod.week => () {
        final monday = DateTime(
          day.year,
          day.month,
          day.day - (day.weekday - DateTime.monday),
        );
        return PeriodRange._(
          period,
          monday,
          DateTime(monday.year, monday.month, monday.day + 7),
        );
      }(),
      SpendPeriod.month => PeriodRange._(
        period,
        DateTime(day.year, day.month),
        DateTime(day.year, day.month + 1),
      ),
    };
  }

  final SpendPeriod period;
  final DateTime start;

  /// The first moment after the period.
  final DateTime end;

  /// The period's last day.
  DateTime get lastDay => DateTime(end.year, end.month, end.day - 1);

  bool contains(DateTime t) => !t.isBefore(start) && t.isBefore(end);

  PeriodRange get previous =>
      PeriodRange.containing(period, DateTime(start.year, start.month, start.day - 1));

  PeriodRange get next => PeriodRange.containing(period, end);

  /// "Saturday, 31 October 2026", "Mon 26 Oct – Sun 1 Nov 2026" or
  /// "October 2026".
  String get label => switch (period) {
    SpendPeriod.day => Formatters.fullDate(start),
    SpendPeriod.week => Formatters.weekRange(start, lastDay),
    SpendPeriod.month => Formatters.monthYear(start),
  };

  /// "Today", "This week" or "This month" when [now] falls inside, else null.
  String? currentLabel(DateTime now) => !contains(now)
      ? null
      : switch (period) {
          SpendPeriod.day => 'Today',
          SpendPeriod.week => 'This week',
          SpendPeriod.month => 'This month',
        };

  @override
  bool operator ==(Object other) =>
      other is PeriodRange &&
      other.period == period &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(period, start, end);
}
