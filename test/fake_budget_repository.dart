import 'dart:async';

import 'package:pennywise/data/budget_repository.dart';
import 'package:pennywise/models/budget_model.dart';

/// In-memory [BudgetRepository] so widget tests don't need Firestore.
class FakeBudgetRepository implements BudgetRepository {
  FakeBudgetRepository([List<BudgetModel> initial = const []]) {
    for (final b in initial) {
      _limits[b.monthId] = b.limit;
    }
  }

  /// Budget limit per "YYYY-MM".
  final _limits = <String, double>{};
  final _controller = StreamController<void>.broadcast();

  double? limitFor(DateTime month) => _limits[BudgetModel.idFor(month)];

  BudgetModel? _current(DateTime month) {
    final limit = limitFor(month);
    return limit == null ? null : BudgetModel(month: month, limit: limit);
  }

  @override
  Stream<BudgetModel?> watchMonth(DateTime month) async* {
    yield _current(month);
    yield* _controller.stream.map((_) => _current(month));
  }

  @override
  Future<void> save(BudgetModel budget) async {
    _limits[budget.monthId] = budget.limit;
    _controller.add(null);
  }

  @override
  Future<void> delete(DateTime month) async {
    _limits.remove(BudgetModel.idFor(month));
    _controller.add(null);
  }
}
