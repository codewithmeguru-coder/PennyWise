import 'package:flutter/material.dart';

import 'transaction_model.dart';

/// A category a transaction can belong to (e.g. Food, Salary).
///
/// Each category is tied to one [TransactionType] so the add form only shows
/// expense categories for expenses and income categories for income.
/// Transfers, savings and debt repayments each have one fixed category.
class TransactionCategory {
  const TransactionCategory({
    required this.id,
    required this.name,
    required this.icon,
    required this.type,
  });

  final String id;
  final String name;
  final IconData icon;
  final TransactionType type;
}

/// The fixed starter categories. Custom categories come in a later stage.
class DefaultCategories {
  DefaultCategories._();

  static const List<TransactionCategory> all = [
    // Expense categories
    TransactionCategory(
      id: 'food',
      name: 'Food',
      icon: Icons.restaurant_rounded,
      type: TransactionType.expense,
    ),
    TransactionCategory(
      id: 'transport',
      name: 'Transport',
      icon: Icons.directions_bus_rounded,
      type: TransactionType.expense,
    ),
    TransactionCategory(
      id: 'bills',
      name: 'Bills',
      icon: Icons.receipt_long_rounded,
      type: TransactionType.expense,
    ),
    TransactionCategory(
      id: 'shopping',
      name: 'Shopping',
      icon: Icons.shopping_bag_rounded,
      type: TransactionType.expense,
    ),
    TransactionCategory(
      id: 'entertainment',
      name: 'Entertainment',
      icon: Icons.movie_rounded,
      type: TransactionType.expense,
    ),
    TransactionCategory(
      id: 'health',
      name: 'Health',
      icon: Icons.favorite_rounded,
      type: TransactionType.expense,
    ),
    TransactionCategory(
      id: 'airtime_data',
      name: 'Airtime & Data',
      icon: Icons.phone_android_rounded,
      type: TransactionType.expense,
    ),
    TransactionCategory(
      id: 'education',
      name: 'Education',
      icon: Icons.school_rounded,
      type: TransactionType.expense,
    ),
    TransactionCategory(
      id: 'housing',
      name: 'Housing',
      icon: Icons.home_work_rounded,
      type: TransactionType.expense,
    ),
    TransactionCategory(
      id: 'cash_withdrawal',
      name: 'Cash withdrawal',
      icon: Icons.local_atm_rounded,
      type: TransactionType.expense,
    ),
    // Provider charges (e.g. the M-Pesa transaction cost). Fees are stored on
    // the transaction they were charged for; the Ledger reports them here.
    TransactionCategory(
      id: 'fees',
      name: 'Transaction fees',
      icon: Icons.request_quote_rounded,
      type: TransactionType.expense,
    ),
    TransactionCategory(
      id: 'other_expense',
      name: 'Other',
      icon: Icons.more_horiz_rounded,
      type: TransactionType.expense,
    ),
    // Used by automatic SMS detection when it can't tell what a payment was
    // for. The user can change it afterwards.
    TransactionCategory(
      id: 'uncategorized',
      name: 'Uncategorized',
      icon: Icons.help_outline_rounded,
      type: TransactionType.expense,
    ),
    // Income categories
    TransactionCategory(
      id: 'salary',
      name: 'Salary',
      icon: Icons.work_rounded,
      type: TransactionType.income,
    ),
    TransactionCategory(
      id: 'freelance',
      name: 'Freelance',
      icon: Icons.laptop_mac_rounded,
      type: TransactionType.income,
    ),
    TransactionCategory(
      id: 'gift',
      name: 'Gift',
      icon: Icons.card_giftcard_rounded,
      type: TransactionType.income,
    ),
    TransactionCategory(
      id: 'money_received',
      name: 'Money received',
      icon: Icons.call_received_rounded,
      type: TransactionType.income,
    ),
    TransactionCategory(
      id: 'cash_deposit',
      name: 'Cash deposit',
      icon: Icons.account_balance_wallet_rounded,
      type: TransactionType.income,
    ),
    TransactionCategory(
      id: 'other_income',
      name: 'Other',
      icon: Icons.more_horiz_rounded,
      type: TransactionType.income,
    ),
    TransactionCategory(
      id: 'uncategorized_income',
      name: 'Uncategorized',
      icon: Icons.help_outline_rounded,
      type: TransactionType.income,
    ),
    // One fixed category each for the kinds that aren't earning or spending.
    TransactionCategory(
      id: 'transfer',
      name: 'Transfer',
      icon: Icons.swap_horiz_rounded,
      type: TransactionType.transfer,
    ),
    TransactionCategory(
      id: 'savings',
      name: 'Savings',
      icon: Icons.savings_rounded,
      type: TransactionType.savingsContribution,
    ),
    TransactionCategory(
      id: 'savings_withdrawal',
      name: 'Savings withdrawal',
      icon: Icons.account_balance_rounded,
      type: TransactionType.savingsWithdrawal,
    ),
    TransactionCategory(
      id: 'debt_repayment',
      name: 'Debt repayment',
      icon: Icons.credit_score_rounded,
      type: TransactionType.debtRepayment,
    ),
  ];

  /// Shown for a category id this version doesn't know (e.g. one added by a
  /// newer version of the app), instead of guessing a wrong one.
  static const unknown = TransactionCategory(
    id: 'unknown',
    name: 'Other',
    icon: Icons.help_outline_rounded,
    type: TransactionType.expense,
  );

  /// Categories from before transfers existed. Cash moving between M-Pesa
  /// and your pocket is a transfer, not spending or income, so new entries
  /// can't pick these; older transactions that use them still display.
  static const retired = {'cash_withdrawal', 'cash_deposit'};

  /// The categories the user can pick for [type]. A refund gives money back
  /// for a purchase, so it uses the expense categories (not fees).
  ///
  /// [retired] categories are left out unless [keep] names one, so editing
  /// an older transaction still shows the category it has.
  static List<TransactionCategory> forType(TransactionType type,
      {String? keep}) {
    final lookup =
        type == TransactionType.refund ? TransactionType.expense : type;
    return all
        .where((c) =>
            c.type == lookup &&
            !(type == TransactionType.refund && c.id == 'fees') &&
            (!retired.contains(c.id) || c.id == keep))
        .toList();
  }

  /// True when [type] has a single fixed category, so the form doesn't ask.
  static bool hasFixedCategory(TransactionType type) => switch (type) {
        TransactionType.transfer ||
        TransactionType.savingsContribution ||
        TransactionType.savingsWithdrawal ||
        TransactionType.debtRepayment =>
          true,
        _ => false,
      };

  /// The fixed category for [type] (see [hasFixedCategory]).
  static String fixedCategoryFor(TransactionType type) => switch (type) {
        TransactionType.transfer => 'transfer',
        TransactionType.savingsContribution => 'savings',
        TransactionType.savingsWithdrawal => 'savings_withdrawal',
        TransactionType.debtRepayment => 'debt_repayment',
        _ => throw ArgumentError('$type has no fixed category'),
      };

  static TransactionCategory byId(String id) =>
      all.firstWhere((c) => c.id == id, orElse: () => unknown);
}
