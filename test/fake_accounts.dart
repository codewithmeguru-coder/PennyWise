import 'dart:async';

import 'package:pennywise/accounts/account_repository.dart';
import 'package:pennywise/accounts/money_account.dart';

/// In-memory [AccountRepository] for tests.
class FakeAccountRepository implements AccountRepository {
  FakeAccountRepository([List<MoneyAccount> initial = const []]) {
    for (final a in initial) {
      accounts[a.id] = a;
    }
  }

  final accounts = <String, MoneyAccount>{};
  final _controller = StreamController<List<MoneyAccount>>.broadcast();

  void _emit() => _controller.add(accounts.values.toList());

  @override
  Stream<List<MoneyAccount>> watchAll() async* {
    yield accounts.values.toList();
    yield* _controller.stream;
  }

  @override
  Future<void> save(MoneyAccount account) async {
    accounts[account.id] = account;
    _emit();
  }

  @override
  Future<void> createMissing(List<MoneyAccount> list) async {
    for (final a in list) {
      accounts.putIfAbsent(a.id, () => a);
    }
    _emit();
  }
}
