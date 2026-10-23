import '../categorization/category_rule.dart';
import '../categorization/category_suggester.dart';
import 'sms_transaction.dart';

/// Picks the category saved for a detected transaction.
///
/// Since Phase 3 this is a thin wrapper over [CategorySuggester]: high and
/// medium suggestions are used; anything it can't tell is saved as
/// "uncategorized" (or "uncategorized_income") for the user to review.
class SmsCategorizer {
  SmsCategorizer._();

  /// The full suggestion, with confidence and reason. [rules] are the
  /// user's learned rules (see `CategoryRule`).
  static Suggestion suggest(SmsTransaction t,
          {Map<String, CategoryRule> rules = const {}}) =>
      CategorySuggester(rules: rules).forSms(t);

  /// The category id to save for [t].
  static String categorize(SmsTransaction t,
      {Map<String, CategoryRule> rules = const {}}) {
    final s = suggest(t, rules: rules);
    if (s.isApplied) return s.categoryId;
    return t.type.isMoneyIn
        ? CategorySuggester.uncategorizedIncome
        : CategorySuggester.uncategorized;
  }
}
