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
