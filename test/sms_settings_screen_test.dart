import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/sms/sms_gateway.dart';

import 'fake_sms.dart';
import 'fake_transaction_repository.dart';
import 'test_app.dart';

Future<void> openSettings(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Settings'));
  await tester.pumpAndSettle();
}

Finder get detectionSwitch => find.byType(Switch);

bool switchValue(WidgetTester tester) =>
    tester.widget<Switch>(detectionSwitch).value;

void main() {
  testWidgets('turning on explains first, then asks Android', (tester) async {
    final gateway = FakeSmsGateway();
    final settings = FakeSmsSettings();
    await pumpApp(tester, sms: gateway, smsSettings: settings);
    await openSettings(tester);

    expect(find.text('Automatic Transaction Detection'), findsOneWidget);
    expect(switchValue(tester), isFalse);

    await tester.tap(detectionSwitch);
    await tester.pumpAndSettle();

    // Explanation is shown and Android has NOT been asked yet.
    expect(find.text('Allow PennyWise to read transaction SMS?'),
        findsOneWidget);
    expect(gateway.permissionRequests, 0);

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(gateway.permissionRequests, 1);
    expect(switchValue(tester), isTrue);
    expect(settings.enabled, isTrue);
  });

  testWidgets('"Not now" in the explanation asks nothing', (tester) async {
    final gateway = FakeSmsGateway();
    await pumpApp(tester, sms: gateway);
    await openSettings(tester);

    await tester.tap(detectionSwitch);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();

    expect(gateway.permissionRequests, 0);
    expect(switchValue(tester), isFalse);
  });

  testWidgets('permission denied: stays off, manual entry still works',
      (tester) async {
    final gateway = FakeSmsGateway(answer: SmsPermissionStatus.denied);
    final settings = FakeSmsSettings();
    final repo = await pumpApp(tester,
        repository: FakeTransactionRepository(),
        sms: gateway,
        smsSettings: settings);
    await openSettings(tester);

    await tester.tap(detectionSwitch);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(switchValue(tester), isFalse);
    expect(settings.enabled, isFalse);
    expect(find.textContaining('You can still add transactions manually'),
        findsOneWidget);

    // Back to the app: adding a transaction by hand still works.
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold).last))
        .removeCurrentSnackBar();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Amount'), '200');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Description'), 'Bread');
    await tester.tap(find.text('Food'));
    await scrollAndTap(tester, 'Save transaction');

    expect(repo.items.single.description, 'Bread');
  });

  testWidgets('permanently denied: explains how to enable it in Settings',
      (tester) async {
    final gateway =
        FakeSmsGateway(answer: SmsPermissionStatus.permanentlyDenied);
    await pumpApp(tester, sms: gateway);
    await openSettings(tester);

    await tester.tap(detectionSwitch);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.text('SMS permission is blocked'), findsOneWidget);
    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();

    expect(gateway.openedSettings, 1);
    expect(switchValue(tester), isFalse);
  });

  testWidgets('turning off', (tester) async {
    final settings = FakeSmsSettings(enabled: true, last: DateTime.now());
    await pumpApp(tester,
        sms: FakeSmsGateway(permissionGranted: true), smsSettings: settings);
    await openSettings(tester);

    expect(switchValue(tester), isTrue);
    await tester.tap(detectionSwitch);
    await tester.pumpAndSettle();

    expect(switchValue(tester), isFalse);
    expect(settings.enabled, isFalse);
  });

  testWidgets('on but permission revoked: shows a warning', (tester) async {
    await pumpApp(tester,
        sms: FakeSmsGateway(permissionGranted: false),
        smsSettings: FakeSmsSettings(enabled: true));
    await openSettings(tester);

    expect(find.textContaining('no longer has SMS permission'), findsOneWidget);
  });

  testWidgets('web / unsupported: the switch is disabled', (tester) async {
    await pumpApp(tester, sms: FakeSmsGateway(isSupported: false));
    await openSettings(tester);

    expect(find.text('Available in the Android app only.'), findsOneWidget);
    expect(tester.widget<Switch>(detectionSwitch).onChanged, isNull);
  });

  testWidgets('a detected SMS shows a notification and appears in the list',
      (tester) async {
    final gateway = FakeSmsGateway(permissionGranted: true);
    final repo = await pumpApp(tester,
        repository: FakeTransactionRepository(),
        sms: gateway,
        smsSettings: FakeSmsSettings(enabled: true, last: DateTime.now()));

    gateway.receive(RawSms(
      sender: 'MPESA',
      body: 'TJ6AB1CD2E Confirmed. Ksh500.00 paid to NAIVAS. on 6/10/26 at '
          '1:20 PM.New M-PESA balance is Ksh2,700.00.',
      date: DateTime.now(),
    ));
    await tester.pumpAndSettle();

    expect(repo.items, hasLength(1));
    expect(
        find.text('New M-Pesa transaction detected: KSh 500.00 — Naivas'),
        findsOneWidget);
    expect(find.text('Naivas'), findsOneWidget); // in Recent transactions
    expect(find.textContaining('M-Pesa'), findsWidgets);

    // "Edit" opens the normal edit form, with the SMS details.
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(find.text('Edit transaction'), findsOneWidget);
    expect(find.text('Detected from M-Pesa SMS'), findsOneWidget);
  });
}
