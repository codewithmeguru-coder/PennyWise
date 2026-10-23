import '../models/transaction_model.dart';

/// What kind of place money is kept in.
enum AccountKind {
  mobileMoney('mobile_money', 'Mobile money'),
  bank('bank', 'Bank'),
  cash('cash', 'Cash'),

  /// Money set aside, e.g. Ziidi or M-Shwari for one SIM.
  savings('savings', 'Savings'),

  /// Money owed, e.g. Fuliza for one SIM. Its balance is negative when
  /// something is owed.
  loan('loan', 'Loan');

  const AccountKind(this.wireName, this.label);
  final String wireName;
  final String label;

  static AccountKind? fromWire(String? v) {
    for (final k in values) {
      if (k.wireName == v) return k;
    }
    return null;
  }
}

/// Who runs the account.
enum AccountProvider {
  safaricom('safaricom', 'Safaricom'),
  airtel('airtel', 'Airtel'),
  equity('equity', 'Equity Bank'),
  otherBank('other_bank', 'Other bank'),
  none('none', 'None');

  const AccountProvider(this.wireName, this.label);
  final String wireName;
  final String label;

  static AccountProvider? fromWire(String? v) {
    for (final p in values) {
      if (p.wireName == v) return p;
    }
    return null;
  }
}

/// One of the user's own accounts, e.g. "SIM 1 M-Pesa", "Fuliza (SIM 2)",
/// "Equity Bank". Stored at `users/{uid}/accounts/{id}`.
///
/// Only accounts the user owns belong here. A bank Paybill someone else
/// receives money on (e.g. "Im Bank C2b") is never an account.
class MoneyAccount {
  const MoneyAccount({
    required this.id,
    required this.name,
    required this.kind,
    this.provider = AccountProvider.none,
    this.simSlot,
    this.parentId,
    this.openingBalance,
    this.openingDate,
    this.active = true,
    this.order = 0,
  });

  final String id;
  final String name;
  final AccountKind kind;
  final AccountProvider provider;

  /// 0 = SIM 1, 1 = SIM 2, for mobile money and its Ziidi / Fuliza
  /// accounts. Null for banks and cash.
  final int? simSlot;

  /// For a savings or loan account tied to one SIM's M-Pesa (Ziidi,
  /// Fuliza): that M-Pesa account's id.
  final String? parentId;

  /// Balance on [openingDate], if the user entered one. Without it the
  /// card's balance is an estimate.
  final double? openingBalance;
  final DateTime? openingDate;

  /// False hides the account without deleting its history.
  final bool active;
  final int order;

  bool get isSim => simSlot != null;

  /// The older single-value account field this account corresponds to, so
  /// transactions stay readable by older code and the existing rules.
  /// Savings and loans have none (they're reached through their own types).
  Account? get legacy => switch (kind) {
        AccountKind.mobileMoney =>
          provider == AccountProvider.airtel ? Account.airtelMoney : Account.mpesa,
        AccountKind.bank => Account.bank,
        AccountKind.cash => Account.cash,
        AccountKind.savings || AccountKind.loan => null,
      };

  /// "SIM 1", "SIM 2" or null.
  String? get simLabel => simSlot == null ? null : 'SIM ${simSlot! + 1}';

  MoneyAccount copyWith({
    String? id,
    String? name,
    double? openingBalance,
    DateTime? openingDate,
    bool? active,
    int? order,
  }) =>
      MoneyAccount(
        id: id ?? this.id,
        name: name ?? this.name,
        kind: kind,
        provider: provider,
        simSlot: simSlot,
        parentId: parentId,
        openingBalance: openingBalance ?? this.openingBalance,
        openingDate: openingDate ?? this.openingDate,
        active: active ?? this.active,
        order: order ?? this.order,
      );

  /// The suggested starter set: for each SIM, its M-Pesa plus that SIM's
  /// Ziidi savings and Fuliza loan; and Cash. Banks are added by hand.
  /// SIM 1 and SIM 2 are always separate accounts.
  static List<MoneyAccount> starterSet() => [
        for (final slot in [0, 1]) ...[
          MoneyAccount(
            id: 'mpesa-sim${slot + 1}',
            name: 'SIM ${slot + 1} M-Pesa',
            kind: AccountKind.mobileMoney,
            provider: AccountProvider.safaricom,
            simSlot: slot,
            order: slot * 10,
          ),
          MoneyAccount(
            id: 'ziidi-sim${slot + 1}',
            name: 'Ziidi (SIM ${slot + 1})',
            kind: AccountKind.savings,
            provider: AccountProvider.safaricom,
            simSlot: slot,
            parentId: 'mpesa-sim${slot + 1}',
            order: slot * 10 + 1,
          ),
          MoneyAccount(
            id: 'fuliza-sim${slot + 1}',
            name: 'Fuliza (SIM ${slot + 1})',
            kind: AccountKind.loan,
            provider: AccountProvider.safaricom,
            simSlot: slot,
            parentId: 'mpesa-sim${slot + 1}',
            order: slot * 10 + 2,
          ),
        ],
        const MoneyAccount(
          id: 'cash',
          name: 'Cash',
          kind: AccountKind.cash,
          order: 30,
        ),
      ];
}
