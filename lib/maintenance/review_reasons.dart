import '../accounts/account_repository.dart';
import '../models/transaction_model.dart';
import 'account_assignment.dart';

/// Why something is in Needs review, in plain words: what PennyWise could
/// not tell from the message, and what it won't guess.
class ReviewReasons {
  ReviewReasons._();

  /// Under an item in the Category tab.
  static String category(TransactionModel t) => t.isDetected
      ? "The message doesn't make the category clear. Pick one; PennyWise "
            'remembers it for this sender.'
      : 'Saved without a category.';

  /// Under an item in the Account tab.
  static String account(TransactionModel t, AccountResolver accounts) {
    final slot = t.simSlot;
    final sim = slot == null ? null : 'SIM ${slot + 1}';
    if (!AccountAssignment.assignable(t)) {
      // Two-sided: a move between the user's own accounts.
      if (AccountAssignment.pairForSim(t.type, t.id, slot, accounts) != null) {
        return 'A move between your accounts on $sim: tap to set both.';
      }
      return sim == null
          ? "A move between two of your accounts, and the message doesn't "
                'say which SIM. Pick both in the form.'
          : 'A move between your accounts on $sim; PennyWise can\'t tell '
                'which two from the message. Pick both in the form.';
    }
    if (sim == null) {
      return "The message doesn't say which SIM received it, so PennyWise "
          "won't guess. Pick its account.";
    }
    final known = AccountAssignment.forKnownSim(t, accounts);
    return known == null
        ? 'Came to $sim, but $sim has no matching account yet.'
        : 'Came to $sim, before your accounts were ready. Tap to put it on '
              '${known.name}.';
  }
}
