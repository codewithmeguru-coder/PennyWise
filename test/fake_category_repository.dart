import 'dart:async';

import 'package:pennywise/data/category_repository.dart';
import 'package:pennywise/data/data_exception.dart';
import 'package:pennywise/models/custom_category.dart';

/// In-memory [CategoryRepository] so widget tests don't need Firestore.
class FakeCategoryRepository implements CategoryRepository {
  FakeCategoryRepository([List<CustomCategory> initial = const []]) {
    for (final c in initial) {
      _items[c.id] = c;
    }
  }

  final _items = <String, CustomCategory>{};
  final _controller = StreamController<void>.broadcast();

  /// When set, [watchAll] fails with this.
  DataException? loadError;

  /// While set, [watchAll] waits before its first list (still loading).
  Completer<void>? hold;

  /// Makes every open [watchAll] fail with [e] after it has loaded.
  void failLater(DataException e) => _controller.addError(e);

  /// When set, the next [create] or [update] fails with this.
  DataException? writeError;

  /// Every write, in order, e.g. "create c_abcdefghij Pets".
  final writes = <String>[];

  List<CustomCategory> get items => [..._items.values];
  CustomCategory? byName(String name) {
    for (final c in _items.values) {
      if (c.name == name) return c;
    }
    return null;
  }

  List<CustomCategory> _all() =>
      [..._items.values]
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  @override
  Stream<List<CustomCategory>> watchAll() async* {
    if (hold case final h?) await h.future;
    if (loadError != null) throw loadError!;
    yield _all();
    yield* _controller.stream.map((_) => _all());
  }

  @override
  Future<void> create(CustomCategory category) async {
    if (writeError case final e?) {
      writeError = null;
      throw e;
    }
    if (_items.containsKey(category.id)) {
      throw const DataException('That category id is taken. Try again.');
    }
    writes.add('create ${category.id} ${category.name}');
    _items[category.id] = category;
    _controller.add(null);
  }

  @override
  Future<void> update(CustomCategory category) async {
    if (writeError case final e?) {
      writeError = null;
      throw e;
    }
    final before = _items[category.id]!;
    // Like the rules: the type never changes.
    assert(before.type == category.type);
    writes.add(
      'update ${category.id} ${category.name} '
      '${category.icon} ${category.active}',
    );
    _items[category.id] = category;
    _controller.add(null);
  }
}
