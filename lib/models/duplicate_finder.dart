import 'ledger.dart';
import 'transaction_model.dart';

/// Possible duplicates between a manual entry and an SMS import: the same
/// money movement recorded twice, once by hand and once from its message.
///
/// Only a warning, never a block: nothing here saves, merges or deletes.
/// SMS against SMS is not compared; the transaction code (the document id)
/// already makes that impossible.
///
/// A manual entry and an SMS import match only when all of these hold:
/// - the same type (a refund never matches an expense);
/// - the same amount to the cent, or the manual amount equals the SMS
///   amount plus its fee (people often type the total they paid);
/// - dated the same calendar day or the day before / after;
/// - the same account where both say which: SIM 1 never matches SIM 2, and
///   Cash never matches M-Pesa (for a transfer, both sides);
/// - neither is already paired with another entry (see [_pairs]).
///
/// Never compared: Fuliza loans (SMS only), Ziidi saves under KSh 10 (the
/// daily automatic ones) and a transfer between two of the user's own
/// mobile-money lines.
class DuplicateFinder {
  DuplicateFinder._();

  /// SMS imports in [existing] that new manual entry [draft] may repeat,
  /// best match first.
  static List<TransactionModel> smsMatchesFor(
    TransactionModel draft,
    List<TransactionModel> existing,
  ) {
    if (draft.isDetected || _excluded(draft)) return const [];
    final others = [for (final t in existing) if (t.id != draft.id) t];
    final taken = _pairs(others);
    final found = [
      for (final s in others)
        if (s.isDetected && !taken.contains(s.id) && _pair(draft, s) != null)
          s,
    ];
    return found..sort((a, b) => _compare(draft, a, b, smsSide: true));
  }

  /// Manual entries in [existing] that SMS import [sms] may repeat, best
  /// match first.
  static List<TransactionModel> manualMatchesFor(
    TransactionModel sms,
    List<TransactionModel> existing,
  ) {
    if (!sms.isDetected || _excluded(sms)) return const [];
    final others = [for (final t in existing) if (t.id != sms.id) t];
    final taken = _pairs(others);
    final found = [
      for (final m in others)
        if (!m.isDetected && !taken.contains(m.id) && _pair(m, sms) != null)
          m,
    ];
    return found..sort((a, b) => _compare(sms, a, b, smsSide: false));
  }

  /// Ids of the entries in [existing] already paired with one another:
  /// each manual entry, oldest first, takes its best unpaired SMS match.
  /// One SMS stands for at most one manual entry, so it isn't offered again
  /// once an earlier entry looks like its twin (no state is stored).
  static Set<String> _pairs(List<TransactionModel> existing) {
    final taken = <String>{};
    final manuals = [
      for (final t in existing)
        if (!t.isDetected && !_excluded(t)) t,
    ]..sort((a, b) => a.date.compareTo(b.date));
    for (final m in manuals) {
      final candidates = [
        for (final s in existing)
          if (s.isDetected && !taken.contains(s.id) && _pair(m, s) != null) s,
      ]..sort((a, b) => _compare(m, a, b, smsSide: true));
      if (candidates.isEmpty) continue;
      taken
        ..add(m.id)
        ..add(candidates.first.id);
    }
    return taken;
  }

  static bool _excluded(TransactionModel t) {
    // Fuliza loans share their code with the payment they funded.
    if (t.id.endsWith('_FULIZA')) return true;
    final isSavings = t.type == TransactionType.savingsContribution ||
        t.type == TransactionType.savingsWithdrawal;
    if (isSavings && t.amount < 10) return true;
    // A move between two of the user's own lines (SIM 1 -> SIM 2).
    if (t.type == TransactionType.transfer &&
        _isWallet(t.effectiveAccount) &&
        _isWallet(t.toAccount ?? t.effectiveAccount) &&
        (t.toAccount == null || t.toAccount == t.effectiveAccount)) {
      return true;
    }
    return false;
  }

  static bool _isWallet(Account? a) =>
      a == Account.mpesa || a == Account.airtelMoney;

  /// How well [manual] and [sms] match: null for no match, otherwise 0 for
  /// the exact amount and 1 for the amount plus fee.
  static int? _pair(TransactionModel manual, TransactionModel sms) {
    if (manual.type != sms.type) return null;
    if (_excluded(manual) || _excluded(sms)) return null;

    final int amountMatch;
    final cents = Ledger.toCents(manual.amount);
    final smsCents = Ledger.toCents(sms.amount);
    final smsFee = Ledger.toCents(sms.fee ?? 0);
    if (cents == smsCents) {
      amountMatch = 0;
    } else if (smsFee > 0 && cents == smsCents + smsFee) {
      amountMatch = 1;
    } else {
      return null;
    }

    if (_dayGap(manual.date, sms.date) > 1) return null;

    if (!_same(manual.accountId, sms.accountId) ||
        !_sameAccount(manual.effectiveAccount, sms.effectiveAccount)) {
      return null;
    }
    if (manual.type == TransactionType.transfer &&
        (!_same(manual.toAccountId, sms.toAccountId) ||
            !_sameAccount(manual.toAccount, sms.toAccount))) {
      return null;
    }
    return amountMatch;
  }

  /// Equal, or at least one of them unknown.
  static bool _same(String? a, String? b) => a == null || b == null || a == b;

  static bool _sameAccount(Account? a, Account? b) =>
      a == null || b == null || a == b;

  static int _dayGap(DateTime a, DateTime b) =>
      DateTime.utc(a.year, a.month, a.day)
          .difference(DateTime.utc(b.year, b.month, b.day))
          .inDays
          .abs();

  /// Orders matches for [manual] against [sms]: exact amount first, then a
  /// word shared by the descriptions, then the closest in time.
  static int _compare(TransactionModel manual, TransactionModel a,
      TransactionModel b, {required bool smsSide}) {
    List<int> key(TransactionModel x) {
      final (m, t) = smsSide ? (manual, x) : (x, manual);
      return [
        _pair(m, t) ?? 9,
        _sharesWord(m.description, t.description) ? 0 : 1,
        m.date.difference(t.date).inMinutes.abs(),
      ];
    }

    final ka = key(a), kb = key(b);
    for (var i = 0; i < ka.length; i++) {
      if (ka[i] != kb[i]) return ka[i].compareTo(kb[i]);
    }
    return 0;
  }

  static bool _sharesWord(String a, String b) {
    Set<String> words(String s) => s
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((w) => w.length > 2)
        .toSet();
    return words(a).intersection(words(b)).isNotEmpty;
  }
}

