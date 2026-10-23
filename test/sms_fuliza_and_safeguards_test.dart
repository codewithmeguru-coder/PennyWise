import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/models/transaction_model.dart';
import 'package:pennywise/sms/sms_gateway.dart';
import 'package:pennywise/sms/sms_import_service.dart';
import 'package:pennywise/sms/sms_parser.dart';

import 'fake_sms.dart';
import 'fake_transaction_repository.dart';
import 'test_app.dart';

// Shapes copied from the real Fuliza messages on the phone; codes and
// amounts are made up. Nothing here touches Firestore.
final when = DateTime(2026, 10, 22, 9, 30);

const drawUpper = 'UJMAB1CD2E Confirmed. Fuliza M-PESA amount is Ksh 50.00. '
    'Access Fee charged Ksh 0.50. Total Fuliza M-PESA outstanding amount is '
    'Ksh150.50 due on 21/11/26. To check daily charges, Dial *234*0#OK Select '
    'Query Charges';
const drawMixedCase = 'UJMAB1CD2F Confirmed. Fuliza M-Pesa amount is Ksh '
    '120.00. Access Fee charged Ksh 1.20. Total Fuliza M-Pesa outstanding '
    'amount is Ksh121.20 due on 21/11/26. To check daily charges, Dial '
    '*334*2*1#OK Select Query Charges';
const repayFull = 'UJMAB1CD2G\n Confirmed. Ksh 151.70 from your M-PESA has '
    'been used to fully pay your outstanding Fuliza M-PESA. Available Fuliza '
    'M-PESA limit is Ksh 500.00. Your M-PESA balance is 248.30.';
const repayPartial = 'UJMAB1CD2H\n Confirmed. Ksh 40.00 from your M-PESA has '
    'been used to partially pay your outstanding Fuliza M-PESA. Your '
    'available Fuliza M-PESA limit is Ksh 389.00. Your M-PESA balance is 0.00.';
const failed = 'Failed. Insufficient funds in your M-PESA account as well as '
    'Fuliza M-PESA to send KSH90.00. Your M-PESA balance KSH2.00.';
const payment = 'UJMAB1CD2E Confirmed. Ksh60.00 paid to MAMA PIMA. on '
    '22/10/26 at 9:30 AM.New M-PESA balance is Ksh0.00. Transaction cost, '
    'Ksh0.00.';
const unknownShape = 'UJMAB1CD2J Confirmed. Your M-PESA PIN has been '
    'changed successfully.';

void main() {
  group('Fuliza parsing', () {
    test('a draw: amount, access fee, and a key separate from the payment',
        () {
      final t = SmsParser.parse(sender: 'MPESA', body: drawUpper, date: when)!;
      expect(t.kind.name, 'fulizaDraw');
      expect(t.amount, 50);
      expect(t.fee, 0.5);
      expect(t.type, TransactionType.transfer); // borrowing, not income
      final pay = SmsParser.parse(sender: 'MPESA', body: payment, date: when)!;
      expect(t.reference, pay.reference); // same code on both SMS
      expect(t.dedupeKey, isNot(pay.dedupeKey));
      expect(t.dedupeKey, endsWith('_FULIZA'));
    });

    test('"M-Pesa" spelling and larger amounts', () {
      final t =
          SmsParser.parse(sender: 'MPESA', body: drawMixedCase, date: when)!;
      expect(t.amount, 120);
      expect(t.fee, 1.2);
    });

    test('repayments, full and partial, are debt repayments with no fee', () {
      for (final (body, amount) in [(repayFull, 151.7), (repayPartial, 40.0)]) {
        final t = SmsParser.parse(sender: 'MPESA', body: body, date: when)!;
        expect(t.kind.name, 'fulizaRepayment');
        expect(t.amount, amount);
        expect(t.fee, isNull);
        expect(t.type, TransactionType.debtRepayment);
        expect(t.dedupeKey, startsWith('mpesa_'));
        expect(t.dedupeKey, isNot(endsWith('_FULIZA')));
      }
    });

    test('"Failed … Fuliza" is not a transaction at all', () {
      expect(SmsParser.parse(sender: 'MPESA', body: failed, date: when), isNull);
      expect(SmsParser.looksLikeTransaction(sender: 'MPESA', body: failed),
          isFalse);
    });

    test('an unknown confirmed message is reported as unreadable', () {
      expect(
          SmsParser.parse(sender: 'MPESA', body: unknownShape, date: when),
          isNull);
      expect(
          SmsParser.looksLikeTransaction(sender: 'MPESA', body: unknownShape),
          isTrue);
    });
  });

  group('import safeguards (in memory)', () {
    late FakeSmsSettings settings;
    late FakeSmsGateway gateway;
    late List<String> saved;
    late SmsImportService service;

    setUp(() async {
      settings = FakeSmsSettings()..enabled = true;
      gateway = FakeSmsGateway(permissionGranted: true);
      saved = [];
      service = SmsImportService(
        gateway: gateway,
        settings: settings,
        save: (t, key) async {
          saved.add(key);
          return true;
        },
      );
      await service.start();
    });

    RawSms sms(String body) =>
        RawSms(sender: 'MPESA', body: body, date: when);

    test('Fuliza messages are held back: not saved, not marked handled', () async {
      expect(await service.handle(sms(drawUpper)), isNull);
      expect(await service.handle(sms(repayFull)), isNull);
      expect(saved, isEmpty);
      expect(settings.handled, isEmpty); // a later import can still add them
      expect(service.skipped[SkipReason.fulizaWaiting], 2);
    });

    test('the payment funded by Fuliza is still imported normally', () async {
      await service.handle(sms(drawUpper));
      final t = await service.handle(sms(payment));
      expect(t, isNotNull);
      expect(saved, ['mpesa_UJMAB1CD2E']);
    });

    test('unreadable transaction messages are counted once; others ignored',
        () async {
      await service.handle(sms(unknownShape));
      await service.handle(sms(unknownShape));
      await service.handle(sms(failed));
      await service.handle(sms('Get 1GB for Ksh 50 today! Dial *544#'));
      expect(service.skipped[SkipReason.unreadable], 1);
      expect(saved, isEmpty);
    });

    test('stale detection: on, but unable to check for over 3 days',
        () async {
      expect(service.isStale, isFalse); // opening the app just checked
      // E.g. the SMS permission was removed: opening can't check any more.
      gateway.permissionGranted = false;
      settings.last = DateTime.now().subtract(const Duration(days: 4));
      await service.start();
      expect(service.isStale, isTrue);
    });
  });

  testWidgets('switching detection on offers to import the last 30 days',
      (tester) async {
    final gateway = FakeSmsGateway(permissionGranted: true);
    gateway.inbox.add(RawSms(
        sender: 'MPESA',
        body: payment,
        date: DateTime.now().subtract(const Duration(days: 5))));
    final repo = FakeTransactionRepository();
    await pumpApp(tester, repository: repo, sms: gateway);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();

    expect(find.text('Also import the last 30 days?'), findsOneWidget);
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();
    expect(repo.items, hasLength(1));
    expect(find.textContaining("doesn't run in the background"), findsOneWidget);
  });
}
