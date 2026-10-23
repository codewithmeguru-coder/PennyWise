/// Turns the "other party" of a transaction into a stable key for matching.
///
/// Pure Dart (no Flutter), so the offline replay tool can use it too.
class MerchantKey {
  MerchantKey._();

  /// "Naivas  Westlands." -> "NAIVAS WESTLANDS": upper case, punctuation
  /// removed, single spaces.
  static String normalize(String name) => name
      .toUpperCase()
      .replaceAll(RegExp(r'[^A-Z0-9 ]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// The name with spaces and dashes removed, for exact product names:
  /// "M-Shwari" and "MSHWARI" both become "MSHWARI".
  static String compact(String name) =>
      name.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  /// True if [phrase] appears in [name] as whole words, e.g. "KFC" in
  /// "KFC JUNCTION" but not in "KFCX".
  static bool containsPhrase(String normalizedName, String phrase) =>
      RegExp('(^| )${RegExp.escape(phrase)}( |\$)').hasMatch(normalizedName);
}
