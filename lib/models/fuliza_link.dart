import 'transaction_model.dart';

/// Which saved payments were paid for with a Fuliza loan.
///
/// When M-Pesa uses Fuliza to complete a payment, two messages share one
/// code: the payment (saved as `mpesa_<code>`) and the loan (saved as
/// `mpesa_<code>_FULIZA`, see `SmsTransaction.dedupeKey`). Matching those
/// keys is the only rule: nothing is guessed from amounts or dates, and
/// nothing is changed; this only labels the payment.
class FulizaLinks {
  FulizaLinks(List<TransactionModel> transactions)
    : _loans = {
        for (final t in transactions)
          if (t.id.endsWith(loanSuffix) && t.reference != null)
            '${t.source.name}_${t.reference}': t,
      };

  static const loanSuffix = '_FULIZA';

  final Map<String, TransactionModel> _loans;

  /// The Fuliza loan that paid for [t], or null if it wasn't one.
  TransactionModel? loanFor(TransactionModel t) {
    if (t.id.endsWith(loanSuffix) ||
        t.type == TransactionType.debtRepayment ||
        t.reference == null) {
      return null;
    }
    final loan = _loans['${t.source.name}_${t.reference}'];
    // The payment's own id is the loan's without the suffix.
    return loan != null && '${t.id}$loanSuffix' == loan.id ? loan : null;
  }

  bool paidWithFuliza(TransactionModel t) => loanFor(t) != null;
}
