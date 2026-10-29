import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/accounts/account_repository.dart';
import 'package:pennywise/accounts/money_account.dart';
import 'package:pennywise/maintenance/account_assignment.dart';
import 'package:pennywise/models/transaction_model.dart';
import 'package:pennywise/sms/sms_gateway.dart';
import 'package:pennywise/sms/sms_import_service.dart';
import 'package:pennywise/sms/sms_parser.dart';
import 'package:pennywise/utils/orientation.dart';

import 'fake_accounts.dart';
import 'fake_sms.dart';
import 'fake_transaction_repository.dart';
import 'test_app.dart';

// Review batch: notifications that go away, portrait without touching the
// phone's auto-rotate, detection that waits for accounts, both accounts of
// a Ziidi or Fuliza move from its SIM, and descriptions from the SMS.
// Codes, names and amounts are made up.

String paidNaivas(String code) =>
    '$code Confirmed. Ksh500.00 paid to NAIVAS. on 6/10/26 at 1:20 PM.New '
    'M-PESA balance is Ksh2,700.00.';

/// Accounts that arrive only when [release] is called, like Firestore's
/// first snapshot arriving after sign-in.
class SlowAccountRepository extends FakeAccountRepository {
  SlowAccountRepository(super.initial);

  final _ready = Completer<void>();
  void release() => _ready.complete();

  @override
  Stream<List<MoneyAccount>> watchAll() async* {
    await _ready.future;
    yield* super.watchAll();
  }
}

TransactionModel move(String id, TransactionType type, {int? sim}) =>
    TransactionModel(
      id: id,
      description: 'x',
      amount: 50,
      type: type,
      categoryId: 'savings',
      date: DateTime(2026, 10, 6),
      source: TransactionSource.mpesa,
      reference: id.replaceFirst('mpesa_', '').replaceFirst('_FULIZA', ''),
      simSlot: sim,
    );

void main() {
  group('notifications', () {
    testWidgets('the "transaction detected" notice goes away by itself', (
      tester,
    ) async {
      final gateway = FakeSmsGateway(permissionGranted: true);
      await pumpApp(
        tester,
        repository: FakeTransactionRepository(),
        sms: gateway,
        smsSettings: FakeSmsSettings(enabled: true, last: DateTime.now()),
      );
      gateway.receive(
        RawSms(
          sender: 'MPESA',
          body: paidNaivas('TJ6AB1CDN1'),
          date: DateTime.now(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final notice = find.text(
        'New M-Pesa transaction detected: KSh 500.00 — Naivas',
      );
      expect(notice, findsOneWidget);
      // Its duration is 6 seconds; a snack bar with a button would
      // otherwise stay until tapped.
      await tester.pump(const Duration(seconds: 1)); // shown; timer starts
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();
      expect(notice, findsNothing);
    });
  });

  group('orientation', () {
    test(
      'portrait for this app only; nothing else is asked of Android',
      () async {
        TestWidgetsFlutterBinding.ensureInitialized();
        final calls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              calls.add(call);
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, null),
        );
        await lockAppToPortrait();
        expect(calls.map((c) => c.method), [
          'SystemChrome.setPreferredOrientations',
        ]);
        expect(calls.single.arguments, ['DeviceOrientation.portraitUp']);
      },
    );
  });

  group('detection waits for the accounts', () {
    testWidgets('an SMS read at sign-in gets its SIM\'s account', (
      tester,
    ) async {
      final gateway = FakeSmsGateway(permissionGranted: true)
        ..inbox.add(
          RawSms(
            sender: 'MPESA',
            body: paidNaivas('TJ6AB1CDN2'),
            date: DateTime.now().subtract(const Duration(minutes: 5)),
            simSlot: 0,
          ),
        );
      final accounts = SlowAccountRepository(MoneyAccount.starterSet());
      final repo = await pumpApp(
        tester,
        repository: FakeTransactionRepository(),
        sms: gateway,
        smsSettings: FakeSmsSettings(
          enabled: true,
          last: DateTime.now().subtract(const Duration(days: 1)),
        ),
        accounts: accounts,
      );
      // Accounts not loaded yet: detection hasn't started, nothing saved.
      expect(repo.items, isEmpty);
      accounts.release();
      await tester.pumpAndSettle();
      final saved = repo.items.single;
      expect(saved.simSlot, 0);
      expect(saved.accountId, 'mpesa-sim1');
    });
  });

  group('both accounts of a move from its SIM', () {
    late AccountStore accounts;
    setUp(() async {
      accounts = AccountStore(FakeAccountRepository(MoneyAccount.starterSet()));
      await Future<void>.delayed(Duration.zero);
    });

    String? pair(TransactionModel t) {
      final p = AccountAssignment.pairForSim(t.type, t.id, t.simSlot, accounts);
      return p == null ? null : '${p.from.id} -> ${p.to.id}';
    }

    test('Ziidi deposit and withdrawal: that SIM\'s M-Pesa and Ziidi', () {
      expect(
        pair(move('mpesa_Z1', TransactionType.savingsContribution, sim: 1)),
        'mpesa-sim2 -> ziidi-sim2',
      );
      expect(
        pair(move('mpesa_Z2', TransactionType.savingsWithdrawal, sim: 0)),
        'mpesa-sim1 -> ziidi-sim1',
      );
    });

    test('Fuliza: a repayment from M-Pesa, a loan into M-Pesa', () {
      expect(
        pair(move('mpesa_R1', TransactionType.debtRepayment, sim: 0)),
        'mpesa-sim1 -> fuliza-sim1',
      );
      expect(
        pair(move('mpesa_L1_FULIZA', TransactionType.transfer, sim: 1)),
        'fuliza-sim2 -> mpesa-sim2',
      );
    });

    test('never guessed: no SIM, or a transfer only the user can place', () {
      expect(
        pair(move('mpesa_Z3', TransactionType.savingsContribution)),
        isNull,
      );
      expect(pair(move('mpesa_T1', TransactionType.transfer, sim: 0)), isNull);
      expect(pair(move('mpesa_E1', TransactionType.expense, sim: 0)), isNull);
    });

    test('a hidden Ziidi account is not used', () async {
      final hidden = AccountStore(
        FakeAccountRepository([
          for (final a in MoneyAccount.starterSet())
            a.id == 'ziidi-sim1' ? a.copyWith(active: false) : a,
        ]),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        AccountAssignment.pairForSim(
          TransactionType.savingsContribution,
          'mpesa_Z4',
          0,
          hidden,
        ),
        isNull,
      );
    });
  });

  group('descriptions from the SMS', () {
    String describe(String body) => SmsImportService.toTransaction(
      SmsParser.parse(sender: 'MPESA', body: body, date: DateTime(2026))!,
    ).description;

    test('sent to and received from a person say so', () {
      expect(
        describe(
          'TJ6AB1CDN3 Confirmed. Ksh500.00 sent to JANE WANJIKU '
          '0722000111 on 9/10/26 at 5:05 PM. New M-PESA balance is '
          'Ksh200.00. Transaction cost, Ksh7.00.',
        ),
        'Sent to Jane Wanjiku',
      );
      expect(
        describe(
          'TJ6AB1CDN4 Confirmed.You have received Ksh2,500.00 from '
          'JANE WANJIKU 0722000111 on 6/10/26 at 4:30 PM  New M-PESA '
          'balance is Ksh5,700.00.',
        ),
        'From Jane Wanjiku',
      );
    });

    test('a payment keeps the business name; Ziidi says deposit or '
        'withdrawal', () {
      expect(describe(paidNaivas('TJ6AB1CDN5')), 'Naivas');
      expect(
        describe(
          'TJ6AB1CDN6 Confirmed. Ksh100.00 sent to ZIIDI on 1/10/26. '
          'New M-PESA balance is Ksh0.00.',
        ),
        'Ziidi deposit',
      );
      expect(
        describe(
          'TJ6AB1CDN7 Confirmed.You have received Ksh500.00 from ZIIDI '
          'on 6/10/26 at 4:30 PM New M-PESA balance is Ksh500.00.',
        ),
        'Ziidi withdrawal',
      );
    });
  });
}
