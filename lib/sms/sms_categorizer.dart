import 'sms_transaction.dart';

/// Picks a category for a detected transaction using simple keyword rules.
///
/// Category ids are the ones in `DefaultCategories`. When nothing matches,
/// the result is "uncategorized" (or "uncategorized_income") so the user can
/// see it needs a category and fix it in the edit form.
class SmsCategorizer {
  SmsCategorizer._();

  /// Expense category id -> words that identify it in the merchant name.
  /// Matched as whole words, case-insensitively. First match wins, so more
  /// specific rules come first.
  static const Map<String, List<String>> expenseKeywords = {
    'airtime_data': [
      'AIRTIME', 'BUNDLE', 'BUNDLES', 'DATA BUNDLES', 'TUNUKIWA', 'OKOA',
    ],
    'education': [
      'SCHOOL', 'ACADEMY', 'UNIVERSITY', 'COLLEGE', 'FEES', 'HELB', 'KCA',
      'STRATHMORE', 'KENYATTA UNIVERSITY', 'JKUAT', 'TUITION',
    ],
    'housing': ['RENT', 'LANDLORD', 'APARTMENTS', 'APARTMENT', 'HOUSING'],
    'transport': [
      'UBER', 'BOLT', 'LITTLE CAB', 'FARAS', 'MATATU', 'SACCO', 'SHELL', 'RUBIS',
      'TOTALENERGIES', 'TOTAL', 'FUEL', 'PETROL', 'NTSA', 'PARKING', 'SGR',
    ],
    'food': [
      'RESTAURANT', 'CAFE', 'CAFFE', 'ARTCAFFE', 'JAVA', 'KFC', 'PIZZA',
      'BURGER', 'CHICKEN', 'GLOVO', 'FOOD', 'FOODS', 'KITCHEN', 'BAKERY',
      'BUTCHERY', 'HOTEL', 'EATERY', 'CHAPATI',
    ],
    'shopping': [
      'NAIVAS', 'CARREFOUR', 'QUICKMART', 'QUICK MART', 'CHANDARANA',
      'MAJID', 'CLEANSHELF', 'MAGUNAS', 'TUSKYS', 'SUPERMARKET', 'MINIMART',
      'JUMIA', 'KILIMALL', 'SHOP', 'STORES', 'MART',
    ],
    'bills': [
      'KPLC', 'KENYA POWER', 'PREPAID', 'POSTPAID', 'WATER', 'ZUKU', 'DSTV',
      'GOTV', 'STARTIMES', 'FIBER', 'FIBRE', 'HOME FIBRE', 'INTERNET', 'NCWSC',
    ],
    'health': [
      'HOSPITAL', 'PHARMACY', 'CHEMIST', 'CLINIC', 'MEDICAL', 'NHIF', 'SHA',
      'DENTAL', 'LABORATORY',
    ],
    'entertainment': [
      'NETFLIX', 'SHOWMAX', 'SPOTIFY', 'CINEMA', 'IMAX', 'YOUTUBE',
    ],
  };

  /// Income category id -> words in the sender's name.
  static const Map<String, List<String>> incomeKeywords = {
    'salary': ['SALARY', 'PAYROLL', 'WAGES', 'STIPEND'],
  };

  /// The category id for [t].
  static String categorize(SmsTransaction t) {
    // Some kinds say what they are without looking at the name.
    switch (t.kind) {
      case SmsTransactionKind.airtime:
        return 'airtime_data';
      case SmsTransactionKind.withdrawal:
        return 'cash_withdrawal';
      case SmsTransactionKind.deposit:
        return 'cash_deposit';
      case SmsTransactionKind.received:
        // Keywords can appear in the name or anywhere in the message
        // (e.g. "... from ACME LTD. Salary for September").
        final income = _match(incomeKeywords,
            '${t.counterparty ?? ''} ${t.maskedText}');
        if (income != null) return income;
        // From a phone number = a person sent it.
        return t.phone != null ? 'money_received' : 'uncategorized_income';
      case SmsTransactionKind.payment:
      case SmsTransactionKind.sent:
        final name = t.counterparty;
        if (name == null) return 'uncategorized';
        return _match(expenseKeywords, name) ?? 'uncategorized';
    }
  }

  static String? _match(Map<String, List<String>> rules, String text) {
    final upper = text.toUpperCase();
    for (final entry in rules.entries) {
      for (final word in entry.value) {
        if (RegExp('\\b${RegExp.escape(word)}\\b').hasMatch(upper)) {
          return entry.key;
        }
      }
    }
    return null;
  }
}
