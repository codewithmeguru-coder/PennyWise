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

/// Scrolls Settings from top to bottom and returns every text seen on
/// the way (the list builds lazily, so not all of it exists at once).
Future<Set<String>> textsInSettings(WidgetTester tester) async {
  final seen = <String>{};
  void collect() => seen.addAll(tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data)
      .whereType<String>());
  final list = find.byType(Scrollable).hitTestable().first;
  collect();
  while (find.text('How it works').hitTestable().evaluate().isEmpty) {
    await tester.drag(list, const Offset(0, -300));
    await tester.pumpAndSettle();
    collect();
  }
  return seen;
}

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
    final seen = await textsInSettings(tester);
    expect(seen, contains('Fix old Ziidi records'));
    expect(seen, contains('Fix moves between your accounts'));
  });

  testWidgets('a new profile does not see them', (tester) async {
    await pump(tester, DateTime(2026, 11, 20));
    await openSettings(tester);
    final seen = await textsInSettings(tester);
    expect(seen, isNot(contains('Fix old Ziidi records')));
    expect(seen, isNot(contains('Fix moves between your accounts')));
    // Everyday entries are still there.
    expect(seen, contains('Import last 30 days'));
  });
}
