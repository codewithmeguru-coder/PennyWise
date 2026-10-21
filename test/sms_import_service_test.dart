import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/data/data_exception.dart';
import 'package:pennywise/models/transaction_model.dart';
import 'package:pennywise/sms/sms_gateway.dart';
import 'package:pennywise/sms/sms_import_service.dart';

import 'fake_sms.dart';
import 'fake_transaction_repository.dart';

RawSms naivasSms(DateTime date, {String code = 'TJ6AB1CD2E'}) => RawSms(
      sender: 'MPESA',
      body: '$code Confirmed. Ksh500.00 paid to NAIVAS. on 6/10/26 at 1:20 PM.'
          'New M-PESA balance is Ksh2,700.00. Transaction cost, Ksh0.00.',
      date: date,
    );

void main() {
  late FakeTransactionRepository repo;
  late FakeSmsGateway gateway;
  late FakeSmsSettings settings;

  SmsImportService service() => SmsImportService(
        gateway: gateway,
        settings: settings,
        save: (t, key) => repo.addDetected(t, dedupeKey: key),
      );

  /// A service that has loaded its settings, like the app's.
  Future<SmsImportService> started() async {
    final sms = service();
    await sms.start();
    return sms;
  }

  setUp(() {
    repo = FakeTransactionRepository();
    gateway = FakeSmsGateway(permissionGranted: true);
    settings = FakeSmsSettings(enabled: true);
  });

  group('duplicate prevention', () {
    test('the same SMS handled twice creates one transaction', () async {
      final sms = await started();
      final now = DateTime.now();

      expect(await sms.handle(naivasSms(now)), isNotNull);
      expect(await sms.handle(naivasSms(now)), isNull);

      expect(repo.items, hasLength(1));
      expect(repo.items.single.id, 'mpesa_TJ6AB1CD2E');
      expect(repo.items.single.categoryId, 'shopping');
      expect(repo.items.single.source, TransactionSource.mpesa);
    });

    test('a live SMS and the next inbox scan do not double up', () async {
      settings.last = DateTime.now().subtract(const Duration(minutes: 5));
      final sms = service();
      await sms.start();

      // Arrives while the app is open -> saved live...
      gateway.receive(naivasSms(DateTime.now()));
      await pumpEventQueue();
      expect(repo.items, hasLength(1));

      // ...and is in the inbox when the app is next resumed.
      settings.last = DateTime.now().subtract(const Duration(minutes: 5));
      await sms.scanRecent();
      await sms.onAppResumed();

      expect(repo.items, hasLength(1));
      sms.dispose();
    });

    test('already in Firestore (e.g. from another phone) is skipped', () async {
      // Different device: no local record, but the document exists.
      await repo.addDetected(
        TransactionModel(
          description: 'Naivas',
          amount: 500,
          type: TransactionType.expense,
          categoryId: 'food', // user already re-categorised it
          date: DateTime(2026, 10, 6),
        ),
        dedupeKey: 'mpesa_TJ6AB1CD2E',
      );

      final sms = await started();
      expect(await sms.handle(naivasSms(DateTime.now())), isNull);
      expect(repo.items, hasLength(1));
      expect(repo.items.single.categoryId, 'food'); // not overwritten
    });

    test('a detected transaction the user deleted is not re-created',
        () async {
      final sms = await started();
      final saved = await sms.handle(naivasSms(DateTime.now()));
      await repo.delete(saved!.id);

      gateway.inbox.add(naivasSms(DateTime.now()));
      await sms.scanRecent();

      expect(repo.items, isEmpty);
    });

    test('different codes are different transactions', () async {
      final sms = await started();
      await sms.handle(naivasSms(DateTime.now(), code: 'TJ6AB1CD2E'));
      await sms.handle(naivasSms(DateTime.now(), code: 'TJ6AB1CD2X'));
      expect(repo.items, hasLength(2));
    });
  });

  group('ON / OFF setting', () {
    test('when off, nothing is read or created', () async {
      settings.enabled = false;
      final sms = service();
      await sms.start();

      gateway.receive(naivasSms(DateTime.now()));
      await pumpEventQueue();

      expect(await sms.handle(naivasSms(DateTime.now())), isNull);
      expect(repo.items, isEmpty);
      sms.dispose();
    });

    test('turning off stops live detection', () async {
      final sms = service();
      await sms.start();
      await sms.disable();

      gateway.receive(naivasSms(DateTime.now()));
      await pumpEventQueue();

      expect(repo.items, isEmpty);
      expect(settings.enabled, isFalse);
      sms.dispose();
    });

    test('turning on imports only new messages, not the whole inbox',
        () async {
      settings = FakeSmsSettings(); // never enabled before
      gateway.inbox.add(naivasSms(DateTime.now().subtract(
          const Duration(days: 3))));
      final sms = service();
      await sms.start();
      await sms.enable();

      expect(repo.items, isEmpty);

      // Old messages only come in when the user asks for them.
      expect(await sms.scanRecent(days: 30), 1);
      expect(repo.items, hasLength(1));
      sms.dispose();
    });

    test('messages that arrived while the app was closed are imported',
        () async {
      settings.last = DateTime.now().subtract(const Duration(hours: 2));
      gateway.inbox
        ..add(naivasSms(DateTime.now().subtract(const Duration(hours: 1))))
        ..add(RawSms(
          sender: 'Mum',
          body: 'Call me when you get home',
          date: DateTime.now().subtract(const Duration(minutes: 30)),
        ));

      final sms = service();
      await sms.start();

      expect(repo.items, hasLength(1)); // the personal SMS is ignored
      expect(settings.last!.isAfter(
          DateTime.now().subtract(const Duration(minutes: 1))), isTrue);
      sms.dispose();
    });
  });

  group('permission', () {
    test('without permission nothing runs, even if switched on', () async {
      gateway.permissionGranted = false;
      final sms = service();
      await sms.start();

      expect(sms.isEnabled, isTrue);
      expect(sms.isActive, isFalse);
      gateway.receive(naivasSms(DateTime.now()));
      await pumpEventQueue();
      expect(repo.items, isEmpty);
      sms.dispose();
    });

    test('unsupported platforms (web) do nothing', () async {
      gateway = FakeSmsGateway(isSupported: false, permissionGranted: true);
      final sms = service();
      await sms.start();
      expect(sms.isActive, isFalse);
      expect(await sms.scanRecent(), 0);
      sms.dispose();
    });
  });

  test('offline: the scan stops and is retried later', () async {
    final start = DateTime.now().subtract(const Duration(hours: 2));
    settings.last = start;
    gateway.inbox.add(naivasSms(DateTime.now()));

    var failing = true;
    final sms = SmsImportService(
      gateway: gateway,
      settings: settings,
      save: (t, key) async {
        if (failing) {
          throw const DataException('Can\'t reach the server.');
        }
        return repo.addDetected(t, dedupeKey: key);
      },
    );
    await sms.start();

    expect(repo.items, isEmpty);
    expect(sms.lastError, isNotNull);
    expect(settings.last, start); // not moved past the failed message
    expect(settings.handled, isEmpty);

    failing = false;
    await sms.onAppResumed();
    expect(repo.items, hasLength(1));
    expect(sms.lastError, isNull);
    sms.dispose();
  });
}
