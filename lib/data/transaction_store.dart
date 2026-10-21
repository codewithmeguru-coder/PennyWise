import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/ledger.dart';
import '../models/monthly_summary.dart';
import '../models/transaction_model.dart';
import 'data_exception.dart';
import 'transaction_repository.dart';

/// Live view of the signed-in user's transactions, plus the totals derived
/// from them. This is the only class screens talk to for data.
///
/// It listens to [TransactionRepository.watchAll], so every change — from
/// this device or another — updates the UI. Writes go straight to the
/// repository; the resulting snapshot updates the list.
class TransactionStore extends ChangeNotifier {
  TransactionStore(this._repository) {
    _listen();
  }

  final TransactionRepository _repository;
  StreamSubscription<List<TransactionModel>>? _subscription;

  List<TransactionModel> _transactions = const [];
  bool _isLoading = true;
  String? _error;

  /// True until the first snapshot arrives.
  bool get isLoading => _isLoading;

  /// A user-friendly message if loading failed, otherwise null.
  String? get error => _error;

  /// All transactions, newest first (the repository orders them).
  List<TransactionModel> get transactions => _transactions;

  List<TransactionModel> recent({int count = 5}) =>
      _transactions.take(count).toList();

  /// All-time totals. Recomputed only when the transactions change.
  Ledger get ledger => _ledger ??= Ledger.of(_transactions);
  Ledger? _ledger;

  /// Money you can spend now (all accounts except savings).
  double get balance => ledger.available;

  /// Money set aside in savings.
  double get savingsBalance => ledger.savingsBalance;

  /// Totals for [month] (only the month and year are used).
  MonthlySummary summaryFor(DateTime month, {double? budget}) =>
      MonthlySummary.calculate(
        transactions: _transactions,
        month: month,
        budget: budget,
      );

  double get monthIncome => summaryFor(DateTime.now()).income;
  double get monthExpenses => summaryFor(DateTime.now()).expenses;

  /// These throw a [DataException] if the write is rejected.
  Future<String> add(TransactionModel transaction) =>
      _repository.add(transaction);

  Future<void> update(TransactionModel transaction) =>
      _repository.update(transaction);

  /// See [TransactionRepository.addDetected].
  Future<bool> addDetected(TransactionModel transaction,
          {required String dedupeKey}) =>
      _repository.addDetected(transaction, dedupeKey: dedupeKey);

  Future<void> delete(String id) => _repository.delete(id);

  /// Re-subscribes after a load error (Firestore closes a failed listener).
  void retry() {
    _isLoading = true;
    _error = null;
    notifyListeners();
    _listen();
  }

  void _listen() {
    _subscription?.cancel();
    _subscription = _repository.watchAll().listen(
      (items) {
        _transactions = List.unmodifiable(items);
        _ledger = null;
        _isLoading = false;
        _error = null;
        notifyListeners();
      },
      onError: (Object e) {
        _isLoading = false;
        _error = DataException.from(e).message;
        notifyListeners();
      },
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
