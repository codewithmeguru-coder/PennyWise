import 'package:flutter/material.dart';

import 'transaction_model.dart';

/// A category a transaction can belong to (e.g. Food, Salary).
///
/// Each category is tied to one [TransactionType] so the add form only shows
/// expense categories for expenses and income categories for income.
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
  ];

  static List<TransactionCategory> forType(TransactionType type) =>
      all.where((c) => c.type == type).toList();

  static TransactionCategory byId(String id) =>
      all.firstWhere((c) => c.id == id, orElse: () => all.first);
}
