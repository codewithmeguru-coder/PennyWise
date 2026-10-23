import 'dart:async';

import 'package:pennywise/categorization/category_rule.dart';
import 'package:pennywise/categorization/category_rule_repository.dart';

/// In-memory [CategoryRuleRepository] for tests.
class FakeCategoryRuleRepository implements CategoryRuleRepository {
  FakeCategoryRuleRepository([List<CategoryRule> initial = const []]) {
    for (final r in initial) {
      rules[r.key] = r;
    }
  }

  final rules = <String, CategoryRule>{};
  final _controller = StreamController<List<CategoryRule>>.broadcast();

  @override
  Stream<List<CategoryRule>> watchAll() async* {
    yield rules.values.toList();
    yield* _controller.stream;
  }

  @override
  Future<void> remember(CategoryRule rule) async {
    final old = rules[rule.key];
    rules[rule.key] = CategoryRule(
      key: rule.key,
      categoryId: rule.categoryId,
      type: rule.type,
      count: (old?.count ?? 0) + 1,
      label: rule.label,
    );
    _controller.add(rules.values.toList());
  }

  @override
  Future<void> delete(String key) async {
    rules.remove(key);
    _controller.add(rules.values.toList());
  }
}
