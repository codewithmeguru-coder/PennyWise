import '../models/transaction_category.dart';
import '../models/transaction_model.dart';

/// Search for the transaction lists. Runs on the transactions already on
/// the phone, so it costs no Firestore reads.
class TransactionSearch {
  TransactionSearch._();

  /// True when every word of [query] is found in [t]: its description,
  /// note, category, account, transaction code or amount. Case doesn't
  /// matter; an empty query matches everything. A number matches the
  /// amount with or without cents and commas ("1000", "1,000", "1000.50").
  static bool matches(TransactionModel t, String query) {
    final words = query.toLowerCase().split(RegExp(r'\s+'))
      ..removeWhere((w) => w.isEmpty);
    if (words.isEmpty) return true;
    final text = [
      t.description,
      t.note ?? '',
      DefaultCategories.byId(t.categoryId).name,
      t.effectiveAccount?.label ?? '',
      t.reference ?? '',
    ].join(' ').toLowerCase();
    return words.every((w) {
      if (text.contains(w)) return true;
      final number = double.tryParse(w.replaceAll(',', ''));
      return number != null && (t.amount - number).abs() < 0.005;
    });
  }

  /// [items] that match [query], in the same order.
  static List<TransactionModel> filter(
          List<TransactionModel> items, String query) =>
      query.trim().isEmpty
          ? items
          : items.where((t) => matches(t, query)).toList();
}
