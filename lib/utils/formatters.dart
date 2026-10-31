/// Small formatting helpers so we don't need the `intl` package yet.
class Formatters {
  Formatters._();

  static const String currencySymbol = 'KSh';

  static const List<String> _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// 12500.5 -> "KSh 12,500.50"
  static String currency(double amount) {
    final fixed = amount.abs().toStringAsFixed(2);
    final parts = fixed.split('.');
    final whole = parts[0].replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'),
      (_) => ',',
    );
    final sign = amount < 0 ? '-' : '';
    return '$sign$currencySymbol $whole.${parts[1]}';
  }

  /// "Today", "Yesterday", or e.g. "12 Sep 2026".
  static String relativeDate(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(date.year, date.month, date.day);
    final diff = today.difference(day).inDays;

    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    return shortDate(date);
  }

  static const List<String> _weekdays = [
    'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday',
    'Sunday',
  ];

  /// e.g. "Saturday, 31 October 2026" (weekday from [DateTime.weekday]).
  static String fullDate(DateTime date) =>
      '${_weekdays[date.weekday - 1]}, ${date.day} ${monthYear(date)}';

  /// e.g. "Mon 26 Oct – Sun 1 Nov 2026"; both years when they differ.
  static String weekRange(DateTime first, DateTime last) {
    String day(DateTime d) =>
        '${_weekdays[d.weekday - 1].substring(0, 3)} ${d.day} '
        '${_months[d.month - 1]}';
    return first.year == last.year
        ? '${day(first)} – ${day(last)} ${last.year}'
        : '${day(first)} ${first.year} – ${day(last)} ${last.year}';
  }

  /// e.g. "12 Sep 2026"
  static String shortDate(DateTime date) =>
      '${date.day} ${_months[date.month - 1]} ${date.year}';

  /// e.g. "September 2026"
  static String monthYear(DateTime date) {
    const full = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    return '${full[date.month - 1]} ${date.year}';
  }
}
