import '../models/transaction_model.dart';
import '../sms/sms_transaction.dart';
import 'builtin_rules.dart';
import 'category_rule.dart';
import 'merchant_key.dart';

/// How sure a suggestion is.
enum Confidence {
  /// Clear from the message itself or a specific known business: applied
  /// automatically.
  high,

  /// A keyword that usually, but not always, means this category. Applied
  /// as before Phase 3 (the old keyword lists did the same); a later stage
  /// marks these "Suggested" so they can be confirmed with one tap.
  medium,

  /// Nothing reliable: left as "Uncategorized" for the user to review.
  low,
}

/// A proposed category, how sure it is, and why (shown to the user).
class Suggestion {
  const Suggestion(this.categoryId, this.confidence, this.reason);

  final String categoryId;
  final Confidence confidence;
  final String reason;

  /// True if the category should be used rather than "Uncategorized".
  bool get isApplied => confidence != Confidence.low;

  @override
  String toString() => '$categoryId ($confidence: $reason)';
}

/// Suggests a category for a transaction. Pure Dart: no Flutter, Firebase
/// or network, so it can be tested and replayed offline.
///
/// Order for a detected SMS transaction:
/// 1. what the message itself says (airtime, cash at an agent, savings);
/// 2. the user's own earlier choice for this merchant (high), see
///    [CategoryRule];
/// 3. a known business name (high);
/// 4. a keyword (medium);
/// 5. otherwise review (low). Payments to a person and to a bank's Paybill
///    always go to review: the message doesn't say what they were for.
class CategorySuggester {
  const CategorySuggester({this.rules = const {}});

  /// The user's learned rules, by [CategoryRule.key].
  final Map<String, CategoryRule> rules;

  static const uncategorized = 'uncategorized';
  static const uncategorizedIncome = 'uncategorized_income';

  Suggestion forSms(SmsTransaction t) {
    final type = t.type;
    switch (type) {
      case TransactionType.transfer:
        return const Suggestion('transfer', Confidence.high,
            'Cash at an agent moves money between M-Pesa and Cash');
      case TransactionType.savingsContribution:
        return Suggestion('savings', Confidence.high,
            'Sent to ${t.counterparty}, a savings product');
      case TransactionType.savingsWithdrawal:
        return Suggestion('savings_withdrawal', Confidence.high,
            'Received from ${t.counterparty}, a savings product');
      default:
        break;
    }

    if (t.kind == SmsTransactionKind.airtime) {
      return const Suggestion(
          'airtime_data', Confidence.high, 'Airtime purchase message');
    }

    // The user's own choice beats everything below, including the
    // "person" and "bank Paybill" review rules: they know what it was for.
    if (CategoryRule.keyFor(t) case final key?) {
      if (rules[key] case final rule? when rule.type == type) {
        return Suggestion(rule.categoryId, Confidence.high,
            'Your earlier choice for ${t.counterparty}');
      }
    }

    final name = MerchantKey.normalize(t.counterparty ?? '');

    if (t.kind == SmsTransactionKind.received) {
      final text = MerchantKey.normalize(t.maskedText);
      if (_hasAny(name, BuiltinRules.salaryWords)) {
        return const Suggestion('salary', Confidence.high, 'Sender name says salary');
      }
      if (_hasAny(text, BuiltinRules.salaryWords)) {
        return const Suggestion(
            'salary', Confidence.medium, 'The message mentions salary');
      }
      if (t.phone != null) {
        return const Suggestion('money_received', Confidence.high,
            'Received from a person (phone number in the message)');
      }
      return const Suggestion(uncategorizedIncome, Confidence.low,
          'Received from a business; the message doesn\'t say what for');
    }

    // Paid or sent.
    if (name.isEmpty) {
      return const Suggestion(
          uncategorized, Confidence.low, 'No name in the message');
    }
    if (t.kind == SmsTransactionKind.sent || t.phone != null) {
      return const Suggestion(uncategorized, Confidence.low,
          'Sent to a person; the message doesn\'t say what for');
    }
    if (_hasAny(name, BuiltinRules.bankWords)) {
      return const Suggestion(uncategorized, Confidence.low,
          'Paid to a bank\'s Paybill; the message doesn\'t say what for');
    }
    return forName(name) ??
        const Suggestion(uncategorized, Confidence.low, 'Name not recognised');
  }

  /// For a typed description (Add form): known names and keywords only,
  /// never higher than medium, because the user is choosing anyway.
  Suggestion? forDescription(String description) {
    final s = forName(MerchantKey.normalize(description));
    if (s == null) return null;
    return Suggestion(s.categoryId, Confidence.medium, s.reason);
  }

  /// Known business (high) or keyword (medium); the longest match wins.
  Suggestion? forName(String normalizedName) {
    final known = _longestMatch(normalizedName, BuiltinRules.knownNames);
    if (known != null) {
      return Suggestion(known.value, Confidence.high,
          'Known business "${known.key}"');
    }
    final keyword = _longestMatch(normalizedName, BuiltinRules.keywords);
    if (keyword != null) {
      return Suggestion(keyword.value, Confidence.medium,
          'Name contains "${keyword.key}"');
    }
    return null;
  }

  static MapEntry<String, String>? _longestMatch(
      String name, Map<String, String> table) {
    MapEntry<String, String>? best;
    for (final entry in table.entries) {
      if (MerchantKey.containsPhrase(name, entry.key) &&
          (best == null || entry.key.length > best.key.length)) {
        best = entry;
      }
    }
    return best;
  }

  static bool _hasAny(String name, List<String> phrases) =>
      phrases.any((p) => MerchantKey.containsPhrase(name, p));
}
