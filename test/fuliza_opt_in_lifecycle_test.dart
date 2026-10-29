import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/accounts/money_account.dart';
import 'package:pennywise/sms/sms_gateway.dart';
import 'package:pennywise/sms/sms_import_service.dart';
import 'package:pennywise/sms/sms_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_accounts.dart';
import 'fake_auth_service.dart';
import 'fake_sms.dart';
import 'fake_transaction_repository.dart';
import 'test_app.dart';

// Live Fuliza import is opt-in: installing, upgrading, opening the app,
// signing in or switching profile never saves a Fuliza loan, repayment or
// fee while it is off, and only an explicit `true` turns it on. The other
// SMS keep working. Codes and amounts are made up.

String draw(String code) =>
    '$code Confirmed. Fuliza M-PESA amount is Ksh 50.00. Access Fee '
    'charged Ksh 0.50. Total Fuliza M-PESA outstanding amount is Ksh50.50 '
    'due on 21/11/26.';
String repay(String code) =>
    '$code Confirmed. Ksh 50.50 from your M-PESA has been used to fully pay '
    'your outstanding Fuliza M-PESA. Available Fuliza M-PESA limit is Ksh '
    '500.00.';
String payment(String code) =>
    '$code Confirmed. Ksh30.00 paid to MAMA PIMA. on 20/10/26 at 9:00 AM.New '
    'M-PESA balance is Ksh0.00. Transaction cost, Ksh0.00.';

RawSms msg(String body, {int ago = 1}) => RawSms(
  sender: 'MPESA',
  body: body,
  date: DateTime.now().subtract(Duration(days: ago)),
  simSlot: 0,
);

/// Fuliza records are saved under `mpesa_<code>_FULIZA` (loans) and
/// `mpesa_<code>` (repayments); these codes are only ever Fuliza here.
bool anyFuliza(FakeTransactionRepository repo) => repo.items.any(
  (t) => t.id.endsWith('_FULIZA') || t.id.startsWith('mpesa_UFZ'),
);

/// Every profile has its SIM accounts, so a Fuliza message could be saved:
/// only the opt-in holds it.
///
/// A phone with detection on, SMS permission given, a Fuliza loan and
/// repayment plus an ordinary payment already in the inbox.
FakeSmsGateway phone() => FakeSmsGateway(permissionGranted: true)
  ..inbox.addAll([
    msg(draw('UFZ0000001')),
    msg(repay('UFZ0000002')),
    msg(payment('UOK0000001')),
  ]);

FakeSmsSettings detectionOn({bool autoFuliza = false}) => FakeSmsSettings(
  enabled: true,
  last: DateTime.now().subtract(const Duration(days: 3)),
)..autoFuliza = autoFuliza;

void main() {
  group('the app, with live Fuliza import off', () {
    testWidgets('install or upgrade, then open: no Fuliza saved, other SMS '
        'are', (tester) async {
      final gateway = phone();
      final settings = detectionOn();
      final repo = await pumpApp(
        tester,
        repository: FakeTransactionRepository(),
        sms: gateway,
        smsSettings: settings,
        accounts: FakeAccountRepository(MoneyAccount.starterSet()),
      );
      expect(repo.items.map((t) => t.id), contains('mpesa_UOK0000001'));
      expect(anyFuliza(repo), isFalse);
      // A Fuliza message arriving while the app is open is held too.
      gateway.receive(msg(draw('UFZ0000003'), ago: 0));
      await tester.pumpAndSettle();
      expect(anyFuliza(repo), isFalse);
      // Opening Needs Review and Settings doesn't turn it on.
      expect(settings.autoFuliza, isFalse);
      // Held, not marked handled: Fuliza history can still bring them in.
      expect(
        await settings.handledKeys(),
        isNot(contains('mpesa_UFZ0000001_FULIZA')),
      );
    });

    testWidgets('signing in: no Fuliza saved', (tester) async {
      final settings = detectionOn();
      final repo = await pumpApp(
        tester,
        auth: FakeAuthService(),
        repository: FakeTransactionRepository(),
        sms: phone(),
        smsSettings: settings,
        accounts: FakeAccountRepository(MoneyAccount.starterSet()),
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Email'),
        'me@example.com',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'secret123',
      );
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      expect(find.text('Available balance'), findsOneWidget);
      expect(repo.items.map((t) => t.id), contains('mpesa_UOK0000001'));
      expect(anyFuliza(repo), isFalse);
      expect(settings.autoFuliza, isFalse);
    });

    testWidgets('switching profile: one profile\'s choice never carries to '
        'another', (tester) async {
      final auth = FakeAuthService();
      final gateway = phone();
      // Profile A turned it on; profile B never did.
      final byUser = <String, FakeSmsSettings>{
        'u-a@example.com': detectionOn(autoFuliza: true),
        'u-b@example.com': detectionOn(),
      };
      final repo = await pumpApp(
        tester,
        auth: auth,
        repository: FakeTransactionRepository(),
        sms: gateway,
        smsSettingsForUser: (uid) => byUser[uid]!,
        accounts: FakeAccountRepository(MoneyAccount.starterSet()),
      );
      await auth.signIn(email: 'b@example.com', password: 'x');
      await tester.pumpAndSettle();
      expect(anyFuliza(repo), isFalse);

      await auth.signOut();
      await tester.pumpAndSettle();
      await auth.signIn(email: 'a@example.com', password: 'x');
      await tester.pumpAndSettle();
      // The harness does see Fuliza when the profile opted in: a new
      // message (accounts loaded by now) is saved.
      gateway.receive(msg(draw('UFZ0000005'), ago: 0));
      await tester.pumpAndSettle();
      expect(repo.items.map((t) => t.id), contains('mpesa_UFZ0000005_FULIZA'));

      await auth.signOut();
      await tester.pumpAndSettle();
      await auth.signIn(email: 'b@example.com', password: 'x');
      await tester.pumpAndSettle();
      gateway.receive(msg(draw('UFZ0000004'), ago: 0));
      await tester.pumpAndSettle();
      expect(
        repo.items.where((t) => t.id == 'mpesa_UFZ0000004_FULIZA'),
        isEmpty,
      );
      expect(byUser['u-b@example.com']!.autoFuliza, isFalse);
    });
  });

  test('an unreadable setting counts as off', () async {
    final saved = <String>[];
    final service = SmsImportService(
      gateway: FakeSmsGateway(permissionGranted: true),
      settings: _UnreadableAutoFuliza(),
      accounts: () => null,
      save: (t, key) async {
        saved.add(key);
        return true;
      },
    );
    await service.start();
    expect(await service.autoFulizaImport(), isFalse);
    expect(await service.handle(msg(draw('UFZ0000006'))), isNull);
    expect(saved, isEmpty);
  });

  group('where the choice is stored', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('missing (new install, reinstall or upgrade): off', () async {
      expect(
        await SharedPrefsSmsSettings(uid: 'a').autoFulizaImport(),
        isFalse,
      );
    });

    test('per profile, kept on this phone after sign-out', () async {
      final a = SharedPrefsSmsSettings(uid: 'a');
      await a.setAutoFulizaImport(true);
      expect(await a.autoFulizaImport(), isTrue);
      expect(
        await SharedPrefsSmsSettings(uid: 'b').autoFulizaImport(),
        isFalse,
      );
      // Signing out drops the objects, not the saved choice.
      expect(await SharedPrefsSmsSettings(uid: 'a').autoFulizaImport(), isTrue);
      await a.setAutoFulizaImport(false);
      expect(await a.autoFulizaImport(), isFalse);
    });

    test('anything but an explicit true is off', () async {
      for (final odd in <Object>['true', 1, 'yes']) {
        SharedPreferences.setMockInitialValues({'sms_a_auto_fuliza': odd});
        expect(
          await SharedPrefsSmsSettings(uid: 'a').autoFulizaImport(),
          isFalse,
          reason: '$odd',
        );
      }
    });
  });
}

class _UnreadableAutoFuliza extends FakeSmsSettings {
  _UnreadableAutoFuliza() : super(enabled: true);

  @override
  Future<bool> autoFulizaImport() async =>
      throw StateError('storage unavailable');
}
