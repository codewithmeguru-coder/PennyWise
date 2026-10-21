/// Form validators shared by more than one screen.
class Validators {
  Validators._();

  /// Digits with an optional decimal point: "5", "5.50", ".5", "10.".
  /// Rejects signs, exponents ("1e3"), commas, "NaN" and "Infinity".
  static final _plainNumber = RegExp(r'^(\d+\.?\d*|\.\d+)$');

  /// A positive money amount with at most 2 decimal places.
  static String? amount(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return 'Enter an amount';

    final amount = double.tryParse(text);
    if (amount == null || !_plainNumber.hasMatch(text)) {
      return 'Enter a valid amount';
    }
    if (amount <= 0) return 'Amount must be greater than 0';

    final dot = text.indexOf('.');
    if (dot != -1 && text.length - dot - 1 > 2) {
      return 'Use at most 2 decimal places';
    }
    // Same upper bound as the Firestore security rules.
    if (amount >= 1000000000) return 'Amount is too large';
    return null;
  }

  /// Required text of at most [max] UTF-16 code units once trimmed.
  ///
  /// That's the unit Firestore rules' `size()` counts (and Dart's
  /// `String.length`), whereas a field's `maxLength` counts visible
  /// characters — so an emoji-heavy value can fit `maxLength` yet be rejected
  /// by the server. Checking here keeps the two in step.
  static String? requiredText(
    String? value, {
    required String emptyMessage,
    required int max,
  }) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return emptyMessage;
    return optionalText(text, max: max);
  }

  /// Like [requiredText], but empty is allowed.
  static String? optionalText(String? value, {required int max}) {
    final text = value?.trim() ?? '';
    return text.length > max ? 'Too long, please shorten it' : null;
  }
}
