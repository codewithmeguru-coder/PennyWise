import 'dart:async';

import 'package:pennywise/accounts/account_repository.dart';
import 'package:pennywise/accounts/anchor_log.dart';
import 'package:pennywise/accounts/money_account.dart';
import 'package:pennywise/data/data_exception.dart';

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

  /// Starting-balance history, as `users/{uid}/balanceAnchors` holds it.
  final anchors = <AnchorChange>[];

  /// When set, the next anchored write fails like Firestore offline would,
  /// writing nothing.
  bool failNextWrite = false;
  var writes = 0;

  void _maybeFail() {
    if (failNextWrite) {
      failNextWrite = false;
      throw const DataException('No connection. Nothing was saved.');
    }
  }

  @override
  Future<List<AnchorChange>> anchorHistory() async => [...anchors];

  @override
  Future<bool> saveWithAnchor(MoneyAccount updated, AnchorChange c) async {
    _maybeFail();
    final current = accounts[updated.id];
    if (current == null) throw const DataException('That account no longer exists.');
    if (AnchorKeeper.sameAnchor(
        current, updated.openingBalance, updated.openingDate)) {
      return false;
    }
    writes++;
    accounts[updated.id] = updated;
    anchors.add(c);
    _emit();
    return true;
  }

  @override
  Future<bool> undoAnchor(MoneyAccount restored, AnchorChange c) async {
    _maybeFail();
    final i = anchors.indexWhere((a) => a.id == c.id);
    final current = accounts[restored.id];
    if (i < 0 ||
        anchors[i].undone ||
        current == null ||
        !AnchorKeeper.sameAnchor(current, c.after, c.afterDate)) {
      return false;
    }
    writes++;
    accounts[restored.id] = restored;
    final a = anchors[i];
    anchors[i] = AnchorChange(
      id: a.id,
      accountId: a.accountId,
      at: a.at,
      reason: a.reason,
      before: a.before,
      beforeDate: a.beforeDate,
      after: a.after,
      afterDate: a.afterDate,
      undone: true,
    );
    _emit();
    return true;
  }
}
