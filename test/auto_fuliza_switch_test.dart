import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/screens/settings_screen.dart';
import 'package:pennywise/sms/fuliza_import.dart';
import 'package:pennywise/sms/sms_import_service.dart';

import 'fake_sms.dart';

/// Settings › "Import Fuliza automatically": off until the user turns it
/// on, and turning it on asks first.
void main() {
  late FakeSmsSettings settings;

  Future<void> open(WidgetTester tester) async {
    settings = FakeSmsSettings(enabled: true);
    final gateway = FakeSmsGateway(permissionGranted: true);
    final service = SmsImportService(
      gateway: gateway,
      settings: settings,
      save: (t, key) async => true,
    );
    await service.start(); // detection on, as on the phone
    final importer = FulizaImporter(
      gateway: gateway,
      settings: settings,
      accounts: () => null,
      existingIds: () => const {},
      save: (t, key) async => true,
      delete: (id) async {},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(smsService: service, fulizaImporter: importer),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Import Fuliza automatically'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  bool switchOn(WidgetTester tester) => tester
      .widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Import Fuliza automatically'),
      )
      .value;

  Future<void> tapSwitch(WidgetTester tester) async {
    await tester.tap(find.text('Import Fuliza automatically'));
    await tester.pumpAndSettle();
  }

  testWidgets('off by default', (tester) async {
    await open(tester);
    expect(switchOn(tester), isFalse);
    expect(settings.autoFuliza, isFalse);
  });

  testWidgets('turning on asks first; Cancel leaves it off', (tester) async {
    await open(tester);
    await tapSwitch(tester);
    expect(find.text('Import Fuliza automatically?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(switchOn(tester), isFalse);
    expect(settings.autoFuliza, isFalse);
  });

  testWidgets('Turn on saves it; turning off needs no question', (
    tester,
  ) async {
    await open(tester);
    await tapSwitch(tester);
    await tester.tap(find.text('Turn on'));
    await tester.pumpAndSettle();
    expect(switchOn(tester), isTrue);
    expect(settings.autoFuliza, isTrue);

    await tapSwitch(tester);
    expect(find.text('Import Fuliza automatically?'), findsNothing);
    expect(switchOn(tester), isFalse);
    expect(settings.autoFuliza, isFalse);
  });
}
