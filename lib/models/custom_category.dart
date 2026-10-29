import 'dart:math';

import 'category_icons.dart';
import 'transaction_category.dart';
import 'transaction_model.dart';

/// A category the user added, stored at `users/{uid}/categories/{id}`.
///
/// [id] is generated once ("c_" + lower-case letters) and never changes:
/// transactions, learned rules and limits refer to it, so renaming changes
/// only [name]. Custom categories are deactivated, never deleted.
class CustomCategory {
  const CustomCategory({
    required this.id,
    required this.name,
    required this.type,
    this.icon = CategoryIcons.fallback,
    this.active = true,
  });

  final String id;
  final String name;

  /// [TransactionType.expense] or [TransactionType.income]; fixed once
  /// created, since changing it would change what past records mean.
  final TransactionType type;

  /// A key of [CategoryIcons.all].
  final String icon;
  final bool active;

  /// What the rules accept as an id. Built-in ids never start with "c_".
  static final validId = RegExp(r'^c_[a-z]{6,30}$');

  /// What the rules accept as an icon key.
  static final validIcon = RegExp(r'^[a-z_]{1,30}$');

  static const maxNameLength = 30;

  /// The most custom categories one user can have.
  static const maxCount = 50;

  /// Names no category may take (they mean "no category" in the app).
  static const reserved = {'uncategorized', 'unknown', 'none'};

  /// A new id: "c_" + 10 random lower-case letters.
  static String newId([Random? random]) {
    final r = random ?? Random.secure();
    return 'c_${String.fromCharCodes([for (var i = 0; i < 10; i++) 97 + r.nextInt(26)])}';
  }

  /// How names are compared: leading and trailing spaces ignored, capitals
  /// ignored.
  static String compareKey(String name) => name.trim().toLowerCase();

  /// Why [name] can't be used, or null when it can. It must be unique among
  /// every category (built-in and custom, active or not, expense and
  /// income); [exceptId] is the category being renamed.
  static String? validateName(String? name, {String? exceptId}) {
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty) return 'Enter a name';
    if (trimmed.length > maxNameLength) {
      return 'Use $maxNameLength characters or fewer';
    }
    final key = compareKey(trimmed);
    if (reserved.contains(key)) return '"$trimmed" is reserved';
    for (final c in DefaultCategories.all) {
      if (c.id != exceptId && compareKey(c.name) == key) {
        return 'A category called "${c.name}" already exists';
      }
    }
    return null;
  }

  CustomCategory copyWith({String? name, String? icon, bool? active}) =>
      CustomCategory(
        id: id,
        name: name ?? this.name,
        type: type,
        icon: icon ?? this.icon,
        active: active ?? this.active,
      );

  /// As the app's lookups see it (see [DefaultCategories]).
  TransactionCategory toCategory() => TransactionCategory(
    id: id,
    name: name,
    icon: CategoryIcons.of(icon),
    type: type,
    isCustom: true,
    active: active,
  );
}
