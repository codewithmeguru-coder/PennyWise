import 'dart:async';

import 'package:pennywise/data/category_budget_repository.dart';
import 'package:pennywise/data/data_exception.dart';
import 'package:pennywise/models/budget_model.dart';
import 'package:pennywise/models/category_budget.dart';

/// In-memory [CategoryBudgetRepository] so widget tests don't need
/// Firestore.
class FakeCategoryBudgetRepository implements CategoryBudgetRepository {
  FakeCategoryBudgetRepository([List<CategoryBudget> initial = const []]) {
    for (final b in initial) {
      _limits[b.id] = b;
    }
  }

  final _limits = <String, CategoryBudget>{};
  final _controller = StreamController<void>.broadcast();

  /// When set, [watchMonth] fails with this.
  DataException? loadError;

  /// When set, the next [save] or [delete] fails with this.
  DataException? writeError;

  /// Every write, in order, e.g. "save 2026-10_food 500.0".
  final writes = <String>[];

  double? limitFor(DateTime month, String categoryId) =>
      _limits[CategoryBudget.idFor(month, categoryId)]?.limit;

  Map<String, double> _month(DateTime month) => {
    for (final b in _limits.values)
      if (b.monthId == BudgetModel.idFor(month)) b.categoryId: b.limit,
  };

  @override
  Stream<Map<String, double>> watchMonth(DateTime month) async* {
    if (loadError != null) throw loadError!;
    yield _month(month);
    yield* _controller.stream.map((_) => _month(month));
  }

  @override
  Future<void> save(CategoryBudget budget) async {
    if (writeError case final e?) {
      writeError = null;
      throw e;
    }
    writes.add('save ${budget.id} ${budget.limit}');
    _limits[budget.id] = budget;
    _controller.add(null);
  }

  @override
  Future<void> delete(DateTime month, String categoryId) async {
    if (writeError case final e?) {
      writeError = null;
      throw e;
    }
    final id = CategoryBudget.idFor(month, categoryId);
    writes.add('delete $id');
    _limits.remove(id);
    _controller.add(null);
  }
}
