import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/maintenance/repair_tools.dart';
import 'package:pennywise/services/auth_service.dart';

import 'fake_auth_service.dart';
import 'fake_sms.dart';
import 'test_app.dart';

// One-off repair tools in Settings: listed for profiles created before this
// release (they have records from earlier versions), not for new ones.

AppUser user({DateTime? createdAt}) => AppUser(
  uid: 'u-repair',
  email: 'pat@example.com',
  displayName: 'Pat',
  createdAt: createdAt,
);

Future<void> openSettings(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  await tester.tap(find.byTooltip('Settings').first);
  await tester.pumpAndSettle();
}

/// Scrolls Settings to the end, so every entry has been built.
Future<void> scrollToEnd(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.text('How it works'),
    300,
    scrollable: find.byType(Scrollable).hitTestable().first,
  );
}

Finder get anyRepairTool => find.byWidgetPredicate(
  (w) =>
      w is Text &&
      (w.data == 'Fix old Ziidi records' ||
          w.data == 'Fix moves between your accounts'),
);

void main() {
  test('only profiles created before this release see them', () {
    expect(RepairTools.shownTo(user(createdAt: DateTime(2026, 10, 1))), isTrue);
    expect(RepairTools.shownTo(user(createdAt: DateTime(2026, 11, 5))), isFalse);
    // Unknown creation time: hidden, never assumed old.
    expect(RepairTools.shownTo(user()), isFalse);
    expect(RepairTools.shownTo(null), isFalse);
  });

  Future<void> pump(WidgetTester tester, DateTime? createdAt) => pumpApp(
    tester,
    auth: FakeAuthService(signedInAs: user(createdAt: createdAt)),
    // Detection on, so the SMS section (where the tools live) is shown.
    sms: FakeSmsGateway(permissionGranted: true),
    smsSettings: FakeSmsSettings(enabled: true, last: DateTime.now()),
  );

  testWidgets('the existing owner still has both tools', (tester) async {
    await pump(tester, DateTime(2026, 9, 1));
    await openSettings(tester);
    await scrollToEnd(tester);
    expect(find.text('Fix old Ziidi records'), findsOneWidget);
    expect(find.text('Fix moves between your accounts'), findsOneWidget);
  });

  testWidgets('a new profile does not see them', (tester) async {
    await pump(tester, DateTime(2026, 11, 20));
    await openSettings(tester);
    await scrollToEnd(tester);
    expect(anyRepairTool, findsNothing);
    // Everyday entries are still there.
    expect(find.text('Import last 30 days'), findsOneWidget);
  });
}
