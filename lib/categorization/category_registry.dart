import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/category_repository.dart';
import '../data/data_exception.dart';
import '../models/category_icons.dart';
import '../models/custom_category.dart';
import '../models/transaction_category.dart';
import '../models/transaction_model.dart';

/// The signed-in user's own categories, kept in step with Firestore and
/// handed to [DefaultCategories], so every lookup (forms, lists, reports,
/// charts, search, suggestions, budgets) sees the same categories.
///
/// One per signed-in user; [dispose] (on sign-out) clears them, so another
/// profile never sees them. Built-in categories always work, even while
/// these are loading or can't be loaded.
class CategoryRegistry extends ChangeNotifier {
  CategoryRegistry(this._repository) {
    _listen();
  }

  void _listen() {
    _sub = _repository.watchAll().listen(
      (list) {
        _categories = list;
        _error = null;
        _loaded = true;
        DefaultCategories.useCustom([for (final c in list) c.toCategory()]);
        notifyListeners();
      },
      onError: (Object e) {
        _error = DataException.from(e).message;
        _loaded = true;
        notifyListeners();
      },
    );
  }

  final CategoryRepository _repository;
  StreamSubscription<List<CustomCategory>>? _sub;

  List<CustomCategory> _categories = const [];
  List<CustomCategory> get categories => _categories;

  bool _loaded = false;
  bool get isLoaded => _loaded;

  String? _error;
  String? get error => _error;

  /// Adding and renaming need the full, current list, so a name already
  /// used can't slip through the duplicate check: only once it has loaded
  /// without an error.
  bool get canEdit => _loaded && _error == null;

  static const notReady =
      'Your categories haven\'t loaded yet. Try again in a moment.';

  /// Loads the categories again, e.g. after an error.
  void retry() {
    _sub?.cancel();
    _loaded = false;
    _error = null;
    notifyListeners();
    _listen();
  }

  CustomCategory? find(String id) {
    for (final c in _categories) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Adds a category. Returns why it couldn't be added (invalid or taken
  /// name, too many), or null once saved.
  Future<String?> add({
    required String name,
    required TransactionType type,
    String icon = CategoryIcons.fallback,
  }) async {
    if (!canEdit) return notReady;
    if (type != TransactionType.expense && type != TransactionType.income) {
      return 'Choose expense or income';
    }
    if (_categories.length >= CustomCategory.maxCount) {
      return 'You can have up to ${CustomCategory.maxCount} categories';
    }
    if (CustomCategory.validateName(name) case final problem?) return problem;
    final category = CustomCategory(
      id: CustomCategory.newId(),
      name: name.trim(),
      type: type,
      icon: CategoryIcons.all.containsKey(icon) ? icon : CategoryIcons.fallback,
    );
    try {
      await _repository.create(category);
    } on DataException catch (e) {
      return e.message;
    }
    return null;
  }

  /// Renames and/or changes the icon of [id]. The id never changes.
  Future<String?> edit(String id, {String? name, String? icon}) async {
    if (!canEdit) return notReady;
    final current = find(id);
    if (current == null) return 'That category no longer exists';
    if (name != null) {
      if (CustomCategory.validateName(name, exceptId: id) case final p?) {
        return p;
      }
    }
    return _save(
      current.copyWith(
        name: name?.trim(),
        icon: icon != null && CategoryIcons.all.containsKey(icon) ? icon : null,
      ),
    );
  }

  /// Deactivates (hidden from new choices) or reactivates [id]. Records
  /// that use it are never changed.
  Future<String?> setActive(String id, bool active) async {
    final current = find(id);
    if (current == null) return 'That category no longer exists';
    return _save(current.copyWith(active: active));
  }

  Future<String?> _save(CustomCategory c) async {
    try {
      await _repository.update(c);
    } on DataException catch (e) {
      return e.message;
    }
    return null;
  }

  @override
  void dispose() {
    _sub?.cancel();
    DefaultCategories.clearCustom();
    super.dispose();
  }
}
