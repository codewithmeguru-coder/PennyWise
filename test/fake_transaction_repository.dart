import 'dart:async';

import 'package:pennywise/data/data_exception.dart';
import 'package:pennywise/data/transaction_repository.dart';
import 'package:pennywise/models/transaction_model.dart';

/// In-memory [TransactionRepository] so widget tests don't need Firestore.
///
/// Test fixtures only: the app itself always uses Firestore.
class FakeTransactionRepository implements TransactionRepository {
  FakeTransactionRepository([List<TransactionModel> initial = const []]) {
    for (final t in initial) {
      _items[t.id] = t;
    }
  }

  final _items = <String, TransactionModel>{};
  final _controller = StreamController<List<TransactionModel>>.broadcast();
  var _nextId = 1;

  /// When set, [watchAll] emits this error instead of data.
  DataException? loadError;

  List<TransactionModel> get items => _sorted();

  List<TransactionModel> _sorted() =>
      _items.values.toList()..sort((a, b) => b.date.compareTo(a.date));

  void _emit() => _controller.add(_sorted());

  @override
  Stream<List<TransactionModel>> watchAll() async* {
    if (loadError != null) throw loadError!;
    yield _sorted();
    yield* _controller.stream;
  }

  @override
  Future<String> add(TransactionModel t) async {
    final id = 'fake-${_nextId++}';
    _items[id] = t.withId(id);
    _emit();
    return id;
  }

  @override
  Future<bool> addDetected(TransactionModel t,
      {required String dedupeKey}) async {
    // Same rule as Firestore: the dedupe key is the document id.
    if (_items.containsKey(dedupeKey)) return false;
    _items[dedupeKey] = t.withId(dedupeKey);
    _emit();
    return true;
  }

  @override
  Future<void> update(TransactionModel t) async {
    if (!_items.containsKey(t.id)) {
      throw const DataException('That item no longer exists.');
    }
    _items[t.id] = t;
    _emit();
  }

  @override
  Future<void> delete(String id) async {
    _items.remove(id);
    _emit();
  }
}

/// A small, fixed set of transactions for tests.
List<TransactionModel> testTransactions() {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day, 12);
  return [
    TransactionModel(
      id: 't1',
      description: 'Lunch',
      amount: 850,
      type: TransactionType.expense,
      categoryId: 'food',
      date: today,
    ),
    TransactionModel(
      id: 't2',
      description: 'Monthly salary',
      amount: 65000,
      type: TransactionType.income,
      categoryId: 'salary',
      date: today.subtract(const Duration(hours: 1)),
    ),
  ];
}
