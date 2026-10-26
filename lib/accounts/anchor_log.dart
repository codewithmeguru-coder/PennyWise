import 'account_repository.dart';
import 'money_account.dart';

/// One change to an account's starting balance (its anchor): what it was,
/// what it became, when and why. Stored in Firestore as
/// `users/{uid}/balanceAnchors/{id}`, in the same write as the account, so
/// the history survives reinstalls and moves with the user. Records are
/// never edited or deleted; Undo only marks one [undone].
class AnchorChange {
  const AnchorChange({
    required this.id,
    required this.accountId,
    required this.at,
    required this.reason,
    this.before,
    this.beforeDate,
    this.after,
    this.afterDate,
    this.undone = false,
  });

  /// The record's id, chosen when the change is made.
  final String id;
  final String accountId;

  /// When the change was made (the record's `createdAt`).
  final DateTime at;

  /// One of [reasons].
  final String reason;

  /// The starting balance it replaced ("previous") and the one it set
  /// ("amount"), each with its effective time. Null: no starting balance.
  final double? before, after;
  final DateTime? beforeDate, afterDate;

  final bool undone;

  /// The reasons the security rules accept.
  static const reasons = [
    'Starting balances',
    'Start over',
    'Edited',
    'Used SMS balance',
  ];
}

/// Changes starting balances with a persistent audit trail, and undoes them.
///
/// - A change is one atomic write of the account and its history record; it
///   only counts as done once that write has succeeded (a failure throws
///   and nothing is saved). Repeating a change the account already holds
///   writes nothing, so a retry can't record it twice.
/// - Undo restores the starting balance before an account's latest change,
///   also atomically, and only while the account still holds the value that
///   change set and the record isn't undone yet: a later edit is never
///   reverted, and Undo can't run twice.
/// - Transactions are never created or changed, and the balance model is
///   unchanged: only transactions from the anchor on count.
class AnchorKeeper {
  AnchorKeeper(this._accounts, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final AccountStore _accounts;
  final DateTime Function() _clock;

  /// Changes for [accountId] (or all), oldest first.
  Future<List<AnchorChange>> history([String? accountId]) async => [
        for (final e in await _accounts.anchorHistory())
          if (accountId == null || e.accountId == accountId) e,
      ];

  /// Saves [updated] (an account with a new starting balance) with its
  /// history record. True once saved; false if the account already held
  /// exactly this (nothing written). Throws `DataException` on failure.
  Future<bool> change(MoneyAccount updated, {required String reason}) {
    final current = _accounts.byId(updated.id);
    final now = _clock();
    return _accounts.saveWithAnchor(
      updated,
      AnchorChange(
        id: '${updated.id}_${now.microsecondsSinceEpoch}',
        accountId: updated.id,
        at: now,
        reason: reason,
        before: current?.openingBalance,
        beforeDate: current?.openingDate,
        after: updated.openingBalance,
        afterDate: updated.openingDate,
      ),
    );
  }

  /// The latest change of [accountId] that Undo would restore, or null.
  Future<AnchorChange?> undoable(String accountId) async {
    final mine = [
      for (final e in await history(accountId))
        if (!e.undone) e,
    ];
    if (mine.isEmpty) return null;
    final last = mine.last;
    final now = _accounts.byId(accountId);
    return now != null && sameAnchor(now, last.after, last.afterDate)
        ? last
        : null;
  }

  /// Restores the starting balance before the latest change of
  /// [accountId]. False if there is nothing to undo, or the account changed
  /// since, or it was already undone (then nothing is written).
  Future<bool> undo(String accountId) async {
    final last = await undoable(accountId);
    final now = _accounts.byId(accountId);
    if (last == null || now == null) return false;
    return _accounts.undoAnchor(
      MoneyAccount(
        id: now.id,
        name: now.name,
        kind: now.kind,
        provider: now.provider,
        simSlot: now.simSlot,
        parentId: now.parentId,
        openingBalance: last.before,
        openingDate: last.beforeDate,
        active: now.active,
        order: now.order,
      ),
      last,
    );
  }

  /// [a] holds this starting balance (to the cent and the millisecond).
  static bool sameAnchor(MoneyAccount a, double? amount, DateTime? date) =>
      (a.openingBalance == null) == (amount == null) &&
      (amount == null ||
          (a.openingBalance! * 100).round() == (amount * 100).round()) &&
      a.openingDate?.millisecondsSinceEpoch == date?.millisecondsSinceEpoch;
}
