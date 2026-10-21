import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_auth_service.dart';
import 'fake_sms.dart';
import 'test_app.dart';

Future<void> openMenu(WidgetTester tester) async {
  // Only the visible tab's ☰ button can be tapped.
  await tester.tap(find.byTooltip('Menu').hitTestable());
  await tester.pumpAndSettle();
}

/// Taps an item inside the open drawer.
Future<void> tapInDrawer(WidgetTester tester, String label) async {
  await tester.tap(
      find.descendant(of: find.byType(Drawer), matching: find.text(label)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('☰ opens the drawer with the profile and every item',
      (tester) async {
    await pumpApp(tester,
        auth: FakeAuthService(signedInAs: FakeAuthService.googleUser));

    expect(find.byType(Drawer), findsNothing);
    await openMenu(tester);

    expect(find.byType(Drawer), findsOneWidget);
    // Profile header
    expect(find.text('Ann Google'), findsOneWidget);
    expect(find.text('ann@gmail.com'), findsOneWidget);
    for (final label in [
      'Dashboard',
      'Transactions',
      'Reports & Budgets',
      'Settings',
      'Automatic Detection',
      'Log out',
    ]) {
      expect(
          find.descendant(of: find.byType(Drawer), matching: find.text(label)),
          findsOneWidget,
          reason: label);
    }
  });

  testWidgets('the existing app bar buttons are still there', (tester) async {
    await pumpApp(tester);
    expect(find.byTooltip('Settings'), findsOneWidget);
    expect(find.byTooltip('Sign out'), findsOneWidget);
  });

  testWidgets('drawer items switch tabs and close the drawer', (tester) async {
    await pumpApp(tester);

    await openMenu(tester);
    await tapInDrawer(tester, 'Transactions');
    expect(find.byType(Drawer), findsNothing);
    expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        1);

    // The ☰ button also works from the other tabs.
    await openMenu(tester);
    await tapInDrawer(tester, 'Reports & Budgets');
    expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        2);

    await openMenu(tester);
    await tapInDrawer(tester, 'Dashboard');
    expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        0);
    expect(find.text('Total balance'), findsOneWidget);
  });

  testWidgets('Settings and Automatic Detection open the settings screen',
      (tester) async {
    await pumpApp(tester);

    await openMenu(tester);
    await tapInDrawer(tester, 'Settings');
    expect(find.text('Automatic Transaction Detection'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();

    await openMenu(tester);
    await tapInDrawer(tester, 'Automatic Detection');
    expect(find.text('Automatic Transaction Detection'), findsOneWidget);
  });

  testWidgets('shows whether automatic detection is on', (tester) async {
    await pumpApp(tester,
        sms: FakeSmsGateway(permissionGranted: true),
        smsSettings: FakeSmsSettings(enabled: true, last: DateTime.now()));

    await openMenu(tester);
    expect(
        find.descendant(of: find.byType(Drawer), matching: find.text('On')),
        findsOneWidget);
  });

  testWidgets('Log out asks for confirmation, then signs out',
      (tester) async {
    await pumpApp(tester);

    await openMenu(tester);
    await tapInDrawer(tester, 'Log out');
    expect(find.text('Sign out?'), findsOneWidget); // same dialog as before

    await tester.tap(find.widgetWithText(TextButton, 'Sign out'));
    await tester.pumpAndSettle();
    expect(find.text('Welcome back'), findsOneWidget);
  });
}
